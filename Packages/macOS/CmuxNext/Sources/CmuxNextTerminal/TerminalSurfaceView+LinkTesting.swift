import AppKit
import GhosttyNextKit

#if DEBUG
// Pointer events for live link checks (`debug.terminal.links`): built here and handed to
// the view's own mouse handlers, so a check takes the path a real pointer takes.
extension TerminalSurfaceView {
    /// A mouse event over viewport cell (`column`, `row`) in this view's window.
    func linkTestEvent(_ type: NSEvent.EventType, column: Int, row: Int, flags: NSEvent.ModifierFlags) -> NSEvent? {
        guard let window, let surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics) else { return nil }
        let x = metrics.padding_left + (Double(column) + 0.5) * metrics.cell_width
        let top = metrics.padding_top + (Double(row) + 0.5) * metrics.cell_height
        let point = NSPoint(x: x, y: bounds.height - top)
        return NSEvent.mouseEvent(with: type, location: convert(point, to: nil), modifierFlags: flags,
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
    }
}
#endif
