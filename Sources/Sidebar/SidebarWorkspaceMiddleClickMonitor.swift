import AppKit

/// Window-scoped middle-click routing for the workspace sidebar.
@MainActor
final class SidebarWorkspaceMiddleClickMonitor {
    private var localMonitor: Any?

    func start(
        window: NSWindow?,
        onMiddleClick: @escaping @MainActor () -> Bool
    ) {
        stop()
        guard let window else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak window] event in
            guard event.buttonNumber == 2, event.window === window else { return event }
            // AppKit invokes local event monitors on the main thread.
            let handled = MainActor.assumeIsolated {
                onMiddleClick()
            }
            return handled ? nil : event
        }
    }

    func stop() {
        guard let localMonitor else { return }
        NSEvent.removeMonitor(localMonitor)
        self.localMonitor = nil
    }

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }
}
