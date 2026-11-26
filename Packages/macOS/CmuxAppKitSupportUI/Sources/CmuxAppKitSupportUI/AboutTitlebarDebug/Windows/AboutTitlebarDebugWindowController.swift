#if canImport(AppKit)

public import AppKit
public import SwiftUI

/// Hosts the ``AboutTitlebarDebugView`` editor in a floating utility panel.
///
/// The controller is built around an injected ``AboutTitlebarDebugStore`` (the
/// single source of truth for the options) and a ``WindowDecorating`` seam used
/// to normalize the panel's own chrome.
public final class AboutTitlebarDebugWindowController: NSWindowController, NSWindowDelegate {
    private let store: AboutTitlebarDebugStore
    private weak var decorator: (any WindowDecorating)?

    /// Creates the controller. The panel is created on first presentation and
    /// released when the user closes it.
    ///
    /// - Parameters:
    ///   - store: The store the editor view reads and mutates.
    ///   - decorator: The seam used to decorate the editor panel itself.
    public init(store: AboutTitlebarDebugStore, decorator: (any WindowDecorating)?) {
        self.store = store
        self.decorator = decorator
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Centers, presents, and reapplies options to open About windows.
    public func show() {
        let window = managedWindow()
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        store.applyToOpenWindows()
    }

    private func managedWindow() -> NSWindow {
        if let window {
            return window
        }
        let window = makeWindow()
        self.window = window
        window.delegate = self
        return window
    }

    private func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 690),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.aboutTitlebarDebug.title",
            defaultValue: "About Titlebar Debug"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.aboutTitlebarDebug")
        window.center()
        window.contentView = NSHostingView(rootView: AboutTitlebarDebugView(store: store))
        decorator?.applyWindowDecorations(to: window)
        return window
    }

    /// Releases the hosted view tree and controller-owned window reference when
    /// AppKit is about to close the managed panel.
    public func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else {
            return
        }
        closing.delegate = nil
        closing.contentView = nil
        closing.contentViewController = nil
        window = nil
    }
}

#endif
