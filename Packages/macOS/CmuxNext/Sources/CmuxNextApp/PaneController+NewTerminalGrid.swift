import AppKit
import CmuxNextDaemon
import CmuxNextTerminal

extension PaneController {
    /// The size a new terminal tab in this pane spawns at (``NewTerminalGrid``),
    /// nil to let the daemon choose.
    var newTerminalSize: CellSize? {
        let host = view.contentHost
        guard let window = host.window else { return nil }
        // The terminal this pane shows now, if any: its view fills the content host.
        let shown = selectedTab.flatMap { services.cache.existingTerminal($0.id)?.session }
            .flatMap { $0.view.superview === host ? $0.gridForNewTerminal : nil }
        let scale = window.backingScaleFactor
        let choice = NewTerminalGrid(shownTerminalGrid: shown, hostSize: host.bounds.size, scale: scale,
                                     cellPixels: services.cache.configuredCellPixelSize(scale: scale),
                                     padding: GhosttyRuntime.shared.terminalPadding)
        return choice.grid.map { CellSize(cols: $0.columns, rows: $0.rows) }
    }
}
