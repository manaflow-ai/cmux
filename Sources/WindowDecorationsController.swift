import AppKit

final class WindowDecorationsController {
    private var observers: [NSObjectProtocol] = []
    private var didStart = false

    func start() {
        guard !didStart else { return }
        didStart = true
        attachToExistingWindows()
        installObservers()
    }

    func apply(to window: NSWindow) {
        let shouldHideButtons = shouldHideTrafficLights(for: window)
        hideStandardButtons(on: window, hidden: shouldHideButtons)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow else { return }
            self.apply(to: window)
        }
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: handler))
        observers.append(center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main, using: handler))
    }

    private func attachToExistingWindows() {
        for window in NSApp.windows {
            apply(to: window)
        }
    }

    private func hideStandardButtons(on window: NSWindow, hidden: Bool) {
        window.standardWindowButton(.closeButton)?.isHidden = hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = hidden
        window.standardWindowButton(.zoomButton)?.isHidden = hidden
    }

    private func shouldHideTrafficLights(for window: NSWindow) -> Bool {
        if window.isSheet {
            return true
        }
        if window is NSPanel {
            return true
        }
        if window.styleMask.contains(.utilityWindow) || window.styleMask.contains(.docModalWindow) {
            return true
        }
        return false
    }
}
