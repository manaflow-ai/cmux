import AppKit

/// Escape cancels the strip's tab or group drag in flight (`TabStripView.cancelDrag`). The strip
/// installs it when a drag begins and removes it when the drag ends or is handed off.
@MainActor final class TabDragEscapeMonitor {
    private weak var strip: TabStripView?
    private var monitor: Any?

    init(strip: TabStripView) { self.strip = strip }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let strip = self?.strip, strip.drag != nil || strip.groups.drag != nil else { return event }
            strip.cancelDrag()
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
