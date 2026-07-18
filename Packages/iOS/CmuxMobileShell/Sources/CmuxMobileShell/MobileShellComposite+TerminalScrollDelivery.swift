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
    public func scrollTerminal(surfaceID: String, lines: Double, col: Int, row: Int) async {
        var prefetchState = terminalScrollbackPrefetchStatesBySurfaceID[surfaceID]
            ?? TerminalScrollbackPrefetchState()
        let maxScrollbackRows = prefetchState.rowsToPrefetch(forScrollLines: lines)
        terminalScrollbackPrefetchStatesBySurfaceID[surfaceID] = prefetchState
        enqueueTerminalScroll(TerminalScrollDelivery(
            surfaceID: surfaceID,
            lines: lines,
            col: col,
            row: row,
            maxScrollbackRows: maxScrollbackRows
        ))
    }

    private func enqueueTerminalScroll(_ delivery: TerminalScrollDelivery) {
        guard delivery.lines != 0 else { return }
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
            let prefetchRenderGrid = await self.performTerminalScroll(delivery)
            let completion = self.terminalScrollDidComplete(delivery: delivery, queueToken: queueToken)
            if completion.shouldDeliverScrollPrefetchRenderGrid, let prefetchRenderGrid {
                self.deliverAuthoritativeTerminalRenderGrid(
                    prefetchRenderGrid,
                    expectedSurfaceID: delivery.surfaceID,
                    source: "scroll_prefetch"
                )
            }
            if let next = completion.next {
                self.sendTerminalScroll(next, queueToken: queueToken)
            }
        }
    }

    func terminalScrollDidComplete(
        delivery: TerminalScrollDelivery,
        queueToken: UUID
    ) -> TerminalScrollDeliveryCompletion {
        guard terminalScrollQueueTokensBySurfaceID[delivery.surfaceID] == queueToken,
              var queue = terminalScrollQueuesBySurfaceID[delivery.surfaceID] else {
            return TerminalScrollDeliveryCompletion(
                next: nil,
                shouldDeliverScrollPrefetchRenderGrid: false
            )
        }
        let completion = queue.completeInFlight(completedDelivery: delivery)
        terminalScrollQueuesBySurfaceID[delivery.surfaceID] = queue
        return completion
    }

    private func performTerminalScroll(_ delivery: TerminalScrollDelivery) async -> MobileTerminalRenderGridFrame? {
        guard let client = remoteClient,
              let workspaceID = workspaceID(forTerminalID: delivery.surfaceID) else {
            return nil
        }
        do {
            let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
            var params: [String: Any] = [
                "workspace_id": remoteWorkspaceID.rawValue,
                "surface_id": delivery.surfaceID,
                "client_id": clientID,
                "delta_lines": delivery.lines,
                "col": delivery.col,
                "row": delivery.row,
            ]
            if let maxScrollbackRows = delivery.maxScrollbackRows {
                params["max_scrollback_rows"] = maxScrollbackRows
            }
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.scroll",
                params: params
            )
            let data = try await client.sendRequest(request)
            guard let maxScrollbackRows = delivery.maxScrollbackRows,
                  maxScrollbackRows > 0,
                  remoteClient === client else {
                return nil
            }
            guard let payload = try? MobileTerminalReplayResponse.decode(data),
                  let renderGrid = payload.renderGrid,
                  renderGrid.surfaceID == delivery.surfaceID else {
                return nil
            }
            return renderGrid
        } catch {
            terminalScrollDeliveryLog.error("scroll forward failed surface=\(delivery.surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
