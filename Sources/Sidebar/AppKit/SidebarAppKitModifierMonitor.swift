import AppKit

/// Window-scoped modifier monitor for native shortcut hints.
///
/// One local event monitor updates a Boolean. The projection source then
/// reconfigures only visible native rows when the Command key changes.
@MainActor
final class SidebarAppKitModifierMonitor {
    private weak var window: NSWindow?
    private var eventMonitor: Any?
    private(set) var isCommandPressed = false
    var onChange: ((Bool) -> Void)?

    func start(window: NSWindow?) {
        self.window = window
        if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
                [weak self] event in
                MainActor.assumeIsolated {
                    self?.receive(event)
                }
                return event
            }
        }
        setCommandPressed(NSEvent.modifierFlags.contains(.command))
    }

    func updateWindow(_ window: NSWindow?) {
        self.window = window
    }

    func stop() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        setCommandPressed(false)
        window = nil
    }

    private func receive(_ event: NSEvent) {
        if let window, let eventWindow = event.window, eventWindow !== window {
            return
        }
        setCommandPressed(event.modifierFlags.contains(.command))
    }

    private func setCommandPressed(_ value: Bool) {
        guard value != isCommandPressed else { return }
        isCommandPressed = value
        onChange?(value)
    }
}
