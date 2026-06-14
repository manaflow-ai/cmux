import CMUXMobileCore
import Foundation

extension TerminalController {
    /// Scrollback rows included in a cold-attach render-grid replay snapshot.
    /// Live render-grid events carry no scrollback; the phone keeps its own
    /// bounded Ghostty scrollback mirror and scrolls that mirror locally while
    /// the Mac remains authoritative.
    nonisolated static let mobileReplayScrollbackLineBudget = 240

    /// Larger history window returned only on explicit mobile scroll prefetch
    /// requests, keeping ordinary scroll RPCs small.
    nonisolated static let mobileScrollPrefetchScrollbackLineBudget = 600

    func mobileTerminalRenderGridFrame(
        terminalPanel: TerminalPanel,
        surfaceID: UUID,
        seq: UInt64,
        scrollbackLines: Int = TerminalController.mobileReplayScrollbackLineBudget
    ) -> MobileTerminalRenderGridFrame? {
        guard surfaceID == terminalPanel.id else { return nil }
        // This is the cold-attach replay / scroll-prefetch path: a full snapshot
        // that establishes a newly mounted iOS surface's baseline. Stamp the same
        // cached inherited theme the live observer uses, so the phone inherits the
        // Mac's palette + chrome on its first frame instead of staying on the
        // Monokai fallback until a later live full event happens to arrive.
        return terminalPanel.surface.mobileRenderGridFrame(
            stateSeq: seq,
            scrollbackLines: scrollbackLines,
            inheritedTheme: MobileTerminalRenderObserver.shared.inheritedTheme()
        )?.frame
    }

    func mobileTerminalScrollResponsePayload(
        workspaceID: UUID,
        terminalPanel: TerminalPanel,
        surfaceID: UUID,
        params: [String: Any]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
        ]
        let scrollbackRows = mobileScrollPrefetchRows(params: params)
        guard scrollbackRows > 0 else { return payload }
        let stateSeq = MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceID) ?? 0
        guard let renderGrid = mobileTerminalRenderGridFrame(
            terminalPanel: terminalPanel,
            surfaceID: surfaceID,
            seq: stateSeq,
            scrollbackLines: scrollbackRows
        ),
            renderGrid.activeScreen == .primary,
            let renderGridObject = try? renderGrid.jsonObject() else {
            return payload
        }
        payload["columns"] = renderGrid.columns
        payload["rows"] = renderGrid.rows
        payload["render_grid"] = renderGridObject
        payload["seq"] = renderGrid.stateSeq
        return payload
    }

    private func mobileScrollPrefetchRows(params: [String: Any]) -> Int {
        let requestedRows = (params["max_scrollback_rows"] as? NSNumber)?.intValue ?? 0
        return min(
            max(0, requestedRows),
            Self.mobileScrollPrefetchScrollbackLineBudget
        )
    }
}
