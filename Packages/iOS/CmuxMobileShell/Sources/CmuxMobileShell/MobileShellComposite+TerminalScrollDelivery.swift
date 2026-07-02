import CmuxMobileRPC
import Foundation
import OSLog

private let terminalScrollDeliveryLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    /// Route a scroll gesture by active screen.
    ///
    /// Primary screen: the phone's local Ghostty mirror owns the viewport. The
    /// Mac's real viewport is never scrolled from here; render-grid exports
    /// follow the Mac's live `vp_top`, so scrolling it would repaint the
    /// phone's grid with the Mac's scrolled viewport while the mirror is also
    /// scrolled locally (the same gesture applied twice, drifting apart). The
    /// RPC is used only to fetch scrollback history windows (`delta_lines = 0`,
    /// which the Mac treats as a no-op scroll), and the mirror rebuilds from
    /// the response while preserving its own scroll position.
    ///
    /// Alternate screen: libghostty needs the wheel on the real PTY
    /// (vim/less/htop mouse reporting), so deltas are forwarded; the
    /// display-only mirror drops its own wheel bytes and the Mac's render-grid
    /// response is the visible update.
    ///
    /// Fire-and-forget and single-flight per surface. Native iOS scrolling can
    /// continue through deceleration after the finger lifts; while one RPC is
    /// in flight, newer deltas are summed into the next request instead of
    /// piling up stale scroll packets.
    public func scrollTerminal(surfaceID: String, lines: Double, col: Int, row: Int) async {
        var prefetchState = terminalScrollbackPrefetchStatesBySurfaceID[surfaceID]
            ?? TerminalScrollbackPrefetchState()
        let delivery = TerminalScrollDelivery.forScrollGesture(
            surfaceID: surfaceID,
            activeScreen: terminalActiveScreenBySurfaceID[surfaceID],
            lines: lines,
            col: col,
            row: row,
            prefetchState: &prefetchState
        )
        terminalScrollbackPrefetchStatesBySurfaceID[surfaceID] = prefetchState
        guard let delivery else { return }
        enqueueTerminalScroll(delivery)
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
                return
            }
            guard let payload = try? MobileTerminalReplayResponse.decode(data),
                  let renderGrid = payload.renderGrid,
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
        }
    }
}
