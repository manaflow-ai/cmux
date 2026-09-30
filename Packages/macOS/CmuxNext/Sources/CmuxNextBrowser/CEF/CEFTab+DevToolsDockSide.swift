import Foundation

extension CEFTab {
    /// The DevTools menu's dock side for a fork side value (0 undocked,
    /// 1 left, 2 bottom, 3 right); nil for a side cmux panes do not offer.
    nonisolated static func devToolsDock(forkSide value: Int) -> BrowserDevToolsDock? {
        switch value {
        case 0: .window
        case 2: .bottom
        case 3: .right
        default: nil  // left: no left dock in the pane layout yet
        }
    }

    /// Chromium reported a dock-side choice from the DevTools frontend menu
    /// (`CMUX_DEVTOOLS_DOCK_SIDE`, fork API v5). Chromium leaves its DevTools
    /// window alone; this moves the same DevTools view through the pane's
    /// dock command (bottom and right keep the frontend's state).
    func devToolsDockSideChosen(_ value: Int) {
        guard devTools.isOpen, let dock = Self.devToolsDock(forkSide: value), dock != devTools.dock else { return }
        performDevTools(.dock(dock))
    }
}
