#if canImport(AppKit)

public import AppKit

#if DEBUG
internal import CMUXDebugLog
#endif

/// NSWindowController for singleton presenters whose window should exist only
/// while it is open.
///
/// The controller owns its managed window while it is visible: it disables
/// AppKit's close-time self-release so teardown is explicit, recreates the
/// window on the next presentation after a close, and tears down the hosted
/// view tree when the window closes. Subclasses provide the window by
/// overriding ``makeWindow()`` and may observe close via
/// ``managedWindowWillClose(_:)``.
@MainActor
open class ReleasingWindowController: NSWindowController, NSWindowDelegate {
    /// Creates the controller, installing `window` as the managed window when
    /// one is supplied.
    public override init(window: NSWindow?) {
        super.init(window: nil)
        if let window {
            installManagedWindow(window)
        }
    }

    /// Creates the controller without a window; the managed window is created
    /// lazily on first presentation via ``makeWindow()``.
    public init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Builds the controller's managed window. Subclasses must override this.
    open func makeWindow() -> NSWindow {
        fatalError("Subclasses must create their managed window.")
    }

    /// Called immediately before the managed window is torn down on close.
    /// Subclasses override to release window-scoped resources.
    open func managedWindowWillClose(_ window: NSWindow) {}

    /// Returns the managed window, creating it via ``makeWindow()`` on first
    /// access.
    @discardableResult
    open func managedWindow() -> NSWindow {
        if let window {
            return window
        }
        let window = makeWindow()
        installManagedWindow(window)
        return window
    }

    /// Presents the managed window, optionally centering it when first shown,
    /// activating the application, and ordering it front regardless of
    /// activation state.
    @discardableResult
    open func showManagedWindow(
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

    /// Tears down the managed window when AppKit reports it is closing.
    public func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else {
            return
        }
        managedWindowWillClose(closing)
        releaseManagedWindow(closing)
    }

    private func releaseManagedWindow(_ window: NSWindow) {
        #if DEBUG
        let identifier = window.identifier?.rawValue ?? "<nil>"
        CMUXDebugLog.logDebugEvent("window.lifecycle.release controller=\(String(describing: type(of: self))) identifier=\(identifier)")
        #endif
        window.delegate = nil
        window.contentView = nil
        window.contentViewController = nil
        self.window = nil
    }
}

#endif
