import AppKit

/// Adapts AppKit's process-local mouse monitor to palette pointer snapshots.
@MainActor
final class AppKitCommandPaletteEventMonitorSource: CommandPaletteEventMonitorSource {
    func addLocalMouseDownMonitor(
        for window: AnyObject,
        handler: @escaping (CommandPalettePointerEvent) -> Void
    ) -> Any? {
        weak var observedWindow = window
        guard let monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { event in
                let eventWindow = event.window
                    ?? (event.windowNumber > 0 ? NSApp.window(withWindowNumber: event.windowNumber) : nil)
                handler(CommandPalettePointerEvent(
                    isInObservedWindow: eventWindow === observedWindow,
                    locationInWindow: event.locationInWindow
                ))
                return event
            }
        ) else {
            return nil
        }
        return monitor
    }

    func removeLocalMonitor(_ monitor: Any) {
        NSEvent.removeMonitor(monitor)
    }
}
