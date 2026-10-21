import AppKit
import CmuxNextDaemon
import CmuxNextBridge
import CmuxNextTerminal
import CmuxNextTerminalGeometry

extension PaneController {
    /// The size a new terminal tab in this pane spawns at (``NewTerminalGrid``),
    /// nil to let the daemon choose.
    var newTerminalSize: CellSize? {
        let host = view.contentHost
        guard let window = host.window else { return nil }
        // The terminal this pane shows now, if any: its view fills the content host.
        let shown = selectedTab.flatMap { services.cache.existingTerminal($0.id)?.session }
            .flatMap { $0.view.superview === host ? $0.gridForNewTerminal : nil }
        return newTerminalSize(shown: shown, hostSize: host.bounds.size, in: window)
    }

    /// The pane's host less its content host, in their own points (a canvas zoom scales
    /// neither): the padding, tab strip and edges around the content, read before a split so the
    /// new pane's content size follows from its host's (``splitTerminalSize(newPane:chrome:)``).
    /// Nil out of a window's layout.
    var contentChrome: CGSize? {
        guard view.window != nil, let pane = workspace?.layoutView.hostSize(of: layoutPaneID) else { return nil }
        let content = view.contentHost.bounds.size
        return CGSize(width: max(0, pane.width - content.width), height: max(0, pane.height - content.height))
    }

    /// The size a split's new terminal spawns at: the new pane's resting size in the window's
    /// layout (it still grows in from this pane's edge), less `chrome` (this pane's, as the new
    /// pane has the same). With it the daemon starts the shell on its prewarmed host at the
    /// grid the view will fit (split_kind.rs `PanePrelaunch`); nil lets the daemon choose.
    func splitTerminalSize(newPane: LayoutPaneID, chrome: CGSize) -> CellSize? {
        guard let window = view.contentHost.window,
              let size = workspace?.layoutView.restingSize(of: newPane) else { return nil }
        let host = CGSize(width: size.width - chrome.width, height: size.height - chrome.height)
        guard host.width > 0, host.height > 0 else { return nil }
        return newTerminalSize(shown: nil, hostSize: host, in: window)
    }

    private func newTerminalSize(shown: TerminalGridSize?, hostSize: CGSize, in window: NSWindow) -> CellSize? {
        let scale = window.backingScaleFactor
        let choice = NewTerminalGrid(shownTerminalGrid: shown, hostSize: hostSize, scale: scale,
                                     cellPixels: services.cache.configuredCellPixelSize(scale: scale),
                                     padding: GhosttyRuntime.shared.terminalPadding)
        return choice.grid.map { CellSize(cols: $0.columns, rows: $0.rows) }
    }
}
