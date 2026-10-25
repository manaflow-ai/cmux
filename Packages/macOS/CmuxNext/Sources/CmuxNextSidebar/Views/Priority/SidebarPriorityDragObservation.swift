import AppKit
import CmuxNextCompat

/// Seam adapter for the Priority panel's short lived drag end signals.
/// AppKit owns the notification and local monitor delivery; the panel owns the gesture state.
@MainActor
final class SidebarPriorityDragObservation {
    private var appObserver: MainActorObservation?
    private var windowObserver: MainActorObservation?
    private var monitor: Any?
    private let onEvent: @MainActor (NSEvent.EventType, NSWindow?) -> Void
    private let onFocusLost: @MainActor () -> Void

    init(
        window: NSWindow?,
        onEvent: @escaping @MainActor (NSEvent.EventType, NSWindow?) -> Void,
        onFocusLost: @escaping @MainActor () -> Void
    ) {
        self.onEvent = onEvent
        self.onFocusLost = onFocusLost
        appObserver = MainActorObservation(NSApplication.didResignActiveNotification, object: NSApp) { [weak self] in
            self?.onFocusLost()
        }
        if let window {
            windowObserver = MainActorObservation(NSWindow.didResignKeyNotification, object: window) { [weak self] in
                // With the button still held the release still comes to this window.
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.onFocusLost() }
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            // main-proof: AppKit local event monitors run on the main thread.
            MainActor.assumeIsolated { self?.onEvent(event.type, event.window) }
            return event
        }
    }

    func cancel() {
        appObserver?.cancel()
        appObserver = nil
        windowObserver?.cancel()
        windowObserver = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
