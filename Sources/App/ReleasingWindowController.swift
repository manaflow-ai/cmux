import AppKit

/// NSWindowController for singleton presenters whose window should exist only
/// while it is open.
@MainActor
class ReleasingWindowController: NSWindowController, NSWindowDelegate {
    override init(window: NSWindow?) {
        super.init(window: nil)
        if let window {
            installManagedWindow(window)
        }
    }

    init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func makeWindow() -> NSWindow {
        fatalError("Subclasses must create their managed window.")
    }

    func managedWindowWillClose(_ window: NSWindow) {}

    @discardableResult
    func managedWindow() -> NSWindow {
        if let window {
            return window
        }
        let window = makeWindow()
        installManagedWindow(window)
        return window
    }

    @discardableResult
    func showManagedWindow(
        centerWhenHidden: Bool = true,
        activateApplication: Bool = false,
        orderFrontRegardless: Bool = false
    ) -> NSWindow {
        let window = managedWindow()
        if centerWhenHidden, !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        if orderFrontRegardless {
            window.orderFrontRegardless()
        }
        if activateApplication {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }
        return window
    }

    private func installManagedWindow(_ window: NSWindow) {
        // The controller owns the window while it is open. Keep AppKit's close-time
        // self-release path disabled so close teardown is explicit and centralized.
        window.isReleasedWhenClosed = false
        self.window = window
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else {
            return
        }
        managedWindowWillClose(closing)
        releaseManagedWindow(closing)
    }

    private func releaseManagedWindow(_ window: NSWindow) {
        #if DEBUG
        let identifier = window.identifier?.rawValue ?? "<nil>"
        cmuxDebugLog("window.lifecycle.release controller=\(String(describing: type(of: self))) identifier=\(identifier)")
        #endif
        window.delegate = nil
        window.contentView = nil
        window.contentViewController = nil
        self.window = nil
    }
}
