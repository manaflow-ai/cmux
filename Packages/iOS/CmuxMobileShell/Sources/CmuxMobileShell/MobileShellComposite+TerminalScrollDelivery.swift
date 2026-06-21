import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import OSLog

private let terminalScrollDeliveryLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    /// Forward a scroll gesture to the Mac's real surface. libghostty does the
    /// mode-correct thing: normal screen moves the viewport into scrollback;
    /// alt screen + mouse reporting encodes mouse-wheel to the PTY for the
    /// program. The render-grid mirrors the result (it exports the live
    /// `vp_top`).
    ///
    /// Fire-and-forget and single-flight per surface. Native iOS scrolling can
    /// continue through deceleration after the finger lifts; while one RPC is
    /// in flight, newer deltas are summed into the next request instead of
    /// piling up stale scroll packets.
    public func scrollTerminal(
        surfaceID: String,
        lines: Double,
        col: Int,
        row: Int,
        hydrateScrollback: Bool = false
    ) async {
        var prefetchState = terminalScrollbackPrefetchStatesBySurfaceID[surfaceID]
            ?? TerminalScrollbackPrefetchState()
        let maxScrollbackRows: Int?
        let scrollbackScope: String?
        if hydrateScrollback {
            maxScrollbackRows = MobileTerminalScrollbackBudget.fullReplayRows
            scrollbackScope = MobileTerminalScrollbackReplayRequest.fullScope
        } else {
            maxScrollbackRows = prefetchState.rowsToPrefetch(forScrollLines: lines)
            scrollbackScope = nil
        }
        terminalScrollbackPrefetchStatesBySurfaceID[surfaceID] = prefetchState
        enqueueTerminalScroll(TerminalScrollDelivery(
            surfaceID: surfaceID,
            lines: lines,
            col: col,
            row: row,
            maxScrollbackRows: maxScrollbackRows,
            scrollbackScope: scrollbackScope
        ))
    }

    private func enqueueTerminalScroll(_ delivery: TerminalScrollDelivery) {
        guard delivery.lines != 0 || delivery.maxScrollbackRows != nil else { return }
        let queueToken = terminalScrollQueueTokensBySurfaceID[delivery.surfaceID] ?? UUID()
        terminalScrollQueueTokensBySurfaceID[delivery.surfaceID] = queueToken
        var queue = terminalScrollQueuesBySurfaceID[delivery.surfaceID] ?? TerminalScrollDeliveryQueue()
        let immediate = queue.enqueue(delivery)
        terminalScrollQueuesBySurfaceID[delivery.surfaceID] = queue
        if let immediate {
            sendTerminalScroll(immediate, queueToken: queueToken)
        }
    }

    private func sendTerminalScroll(_ delivery: TerminalScrollDelivery, queueToken: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performTerminalScroll(delivery)
            self.terminalScrollDidComplete(surfaceID: delivery.surfaceID, queueToken: queueToken)
        }
    }

    func terminalScrollDidComplete(surfaceID: String, queueToken: UUID) {
        guard terminalScrollQueueTokensBySurfaceID[surfaceID] == queueToken,
              var queue = terminalScrollQueuesBySurfaceID[surfaceID] else { return }
        let next = queue.completeInFlight()
        terminalScrollQueuesBySurfaceID[surfaceID] = queue
        if let next {
            sendTerminalScroll(next, queueToken: queueToken)
        }
    }

    private func performTerminalScroll(_ delivery: TerminalScrollDelivery) async {
        guard let client = remoteClient,
              let workspaceID = workspaceID(forTerminalID: delivery.surfaceID) else {
            return
        }
        do {
            var params: [String: Any] = [
                "workspace_id": workspaceID.rawValue,
                "surface_id": delivery.surfaceID,
                "client_id": clientID,
                "delta_lines": delivery.lines,
                "col": delivery.col,
                "row": delivery.row,
            ]
            if let maxScrollbackRows = delivery.maxScrollbackRows {
                params["max_scrollback_rows"] = maxScrollbackRows
            }
            if let scrollbackScope = delivery.scrollbackScope {
                params[MobileTerminalScrollbackReplayRequest.scopeParameter] = scrollbackScope
            }
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.scroll",
                params: params
            )
            let data = try await client.sendRequest(request)
            guard let maxScrollbackRows = delivery.maxScrollbackRows,
                  maxScrollbackRows > 0,
                  remoteClient === client else {
                return
            }
            guard let payload = try? MobileTerminalReplayResponse.decode(data) else {
                return
            }
            let envelope = payload.renderGridEnvelope?.frame.surfaceID == delivery.surfaceID ? payload.renderGridEnvelope :
                payload.renderGrid.flatMap { renderGrid in
                    guard renderGrid.surfaceID == delivery.surfaceID else { return nil }
                    return try? MobileTerminalRenderGridEnvelope.snapshot(renderGrid)
                }
            guard let envelope else { return }
            deliverAuthoritativeTerminalRenderGrid(
                envelope,
                expectedSurfaceID: delivery.surfaceID,
                source: "scroll_prefetch"
            )
        } catch {
            terminalScrollDeliveryLog.error("scroll forward failed surface=\(delivery.surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }
}
