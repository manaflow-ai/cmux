import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import OSLog

private let terminalScrollDeliveryLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    /// The phone owns primary-screen scrolling for this surface: screen-anchored
    /// render grid with a CONFIRMED primary screen. The same condition suppresses
    /// the Mac scroll RPC in `scrollTerminal` and routes the local mirror's
    /// pixel-precise scroll path.
    public func ownsLocalPrimaryScreenScroll(surfaceID: String) -> Bool {
        usesScreenAnchoredRenderGrid
            && terminalActiveScreenBySurfaceID[surfaceID] == .primary
    }

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
        // Screen-anchored sessions own primary-screen scrolling: the gesture
        // already moved the local mirror's viewport over locally accumulated
        // scrollback, the Mac's viewport is not shared, and no prefetch window
        // is needed. Only alternate-screen scrolls still round-trip (they are
        // mouse-wheel input for the TUI, not viewport movement). Suppress only
        // on a CONFIRMED primary screen: with no per-surface entry yet (before
        // the first frame, after surface removal) the screen is unknown, and
        // dropping what may be alternate-screen wheel input would eat TUI
        // scrolling, while forwarding a primary-screen scroll merely moves the
        // Mac's own viewport, which screen-anchored frames ignore.
        if ownsLocalPrimaryScreenScroll(surfaceID: surfaceID) {
            return
        }
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
            recordAppEvent(
                .terminalScrollFailed,
                correlationID: delivery.surfaceID,
                failure: .offline
            )
            return
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
            recordAppEvent(
                .terminalScrollSent,
                correlationID: delivery.surfaceID
            )
            guard let maxScrollbackRows = delivery.maxScrollbackRows,
                  maxScrollbackRows > 0,
                  remoteClient === client else {
                return
            }
            // The prefetch payload is a full replay response (render grid plus
            // deep scrollback); decode it off the main actor like the replay
            // path. The decode suspends, so re-validate the client identity
            // afterwards: a reconnect while decoding means this payload
            // describes the previous session.
            let decoded = await Self.decodeTerminalReplayResponseOffMain(data)
            guard remoteClient === client,
                  let renderGrid = decoded.payload?.renderGrid,
                  renderGrid.surfaceID == delivery.surfaceID else {
                return
            }
            deliverAuthoritativeTerminalRenderGrid(
                renderGrid,
                expectedSurfaceID: delivery.surfaceID,
                source: "scroll_prefetch"
            )
        } catch {
            terminalScrollDeliveryLog.error("scroll forward failed surface=\(delivery.surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            recordAppEvent(
                .terminalScrollFailed,
                correlationID: delivery.surfaceID,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }
}
