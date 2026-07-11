import AppKit

/// Adapts AppKit's process-local mouse monitor to palette pointer snapshots.
@MainActor
final class AppKitCommandPaletteEventMonitorSource: CommandPaletteEventMonitorSource {
    func addLocalMouseDownMonitor(
        for window: AnyObject,
        handler: @escaping (CommandPalettePointerEvent) -> Void
    ) -> Any {
        weak let observedWindow = window
        return NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            let eventWindow = event.window
                ?? (event.windowNumber > 0 ? NSApp.window(withWindowNumber: event.windowNumber) : nil)
            handler(CommandPalettePointerEvent(
                isInObservedWindow: eventWindow === observedWindow,
                locationInWindow: event.locationInWindow
            ))
            return event
        } as Any
    }

    func removeLocalMonitor(_ monitor: Any) {
        NSEvent.removeMonitor(monitor)
    }
}
