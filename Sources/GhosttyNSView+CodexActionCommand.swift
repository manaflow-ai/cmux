import AppKit
import CmuxTerminalCore
import GhosttyKit

extension GhosttyNSView {
    private func codexActionCell(at point: NSPoint, surface: ghostty_surface_t) -> (TerminalPanel, CodexActionCommand)? {
        guard let terminalSurface, let panel = codexActionPanel(), bounds.contains(point) else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        var scrollbar = ghostty_surface_scrollbar_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), ghostty_surface_scrollbar(surface, &scrollbar), metrics.rows > 0, metrics.columns > 0,
              scrollbar.offset + scrollbar.len >= scrollbar.total else { return nil }
        let cellWidth = bounds.width / CGFloat(metrics.columns)
        let cellHeight = bounds.height / CGFloat(metrics.rows)
        let row = max(0, min(Int(metrics.rows) - 1, Int((bounds.height - point.y) / cellHeight)))
        let column = max(0, min(Int(metrics.columns) - 1, Int(point.x / cellWidth)))
        guard let line = terminalSurface.readText(region: .viewportRow(row, columns: Int(metrics.columns))),
              let command = CodexActionCommandDetector().command(in: line, atColumn: column) else { return nil }
        return (panel, command)
    }

    private func codexActionPanel() -> TerminalPanel? {
        guard let terminalSurface else { return nil }
        if let dock = DockSplitStore.liveStore(containingPanel: terminalSurface.id) {
            return dock.panels[terminalSurface.id] as? TerminalPanel
        }
        return terminalSurface.owningWorkspace()?.terminalPanel(for: terminalSurface.id)
    }

    @discardableResult
    func handleCodexActionCommand(at point: NSPoint, surface: ghostty_surface_t) -> Bool {
        guard let (panel, command) = codexActionCell(at: point, surface: surface) else { return false }
        return panel.sendInputResult(command.command + "\r").accepted
    }

    func updateCodexActionCommandHover(at point: NSPoint, surface: ghostty_surface_t) {
        guard codexActionCell(at: point, surface: surface) != nil else { return }
        NSCursor.pointingHand.set()
    }
}
