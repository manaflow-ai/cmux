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

    /// Creates the controller and builds its panel.
    ///
    /// - Parameters:
    ///   - store: The store the editor view reads and mutates.
    ///   - decorator: The seam used to decorate the editor panel itself.
    public init(store: AboutTitlebarDebugStore, decorator: (any WindowDecorating)?) {
        self.store = store
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
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Centers, presents, and reapplies options to open About windows.
    public func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        store.applyToOpenWindows()
    }
}

#endif
