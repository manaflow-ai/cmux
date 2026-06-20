#if canImport(AppKit)

public import AppKit
internal import SwiftUI

/// Presents the "About cmux" window (`cmux.about`).
///
/// The controller reuses ``ReleasingWindowController``'s recreate-on-reopen
/// teardown and builds the fixed 360x520 titled/closable/miniaturizable window.
/// Its two app reach-ups are injected as seams: the ``AboutTitlebarDebugStore``
/// applies the live About Titlebar Debug options to the window, and the
/// ``WindowDecorating`` decorator applies the app's standard window chrome.
/// Content (``AboutPanelView``) is built from injected localized strings and an
/// injected closure that opens the Acknowledgments window.
public final class AboutWindowController: ReleasingWindowController {
    private let store: AboutTitlebarDebugStore
    private weak var decorator: (any WindowDecorating)?
    private let strings: AboutPanelStrings
    private let showAcknowledgments: @MainActor () -> Void

    /// Creates the controller. The window is built lazily on first presentation.
    ///
    /// - Parameters:
    ///   - store: Applies the live About Titlebar Debug options to the window.
    ///   - decorator: Applies the app's standard window chrome.
    ///   - strings: Localized labels for the About panel.
    ///   - showAcknowledgments: Opens the Acknowledgments window, invoked by the
    ///     panel's Licenses button.
    public init(
        store: AboutTitlebarDebugStore,
        decorator: (any WindowDecorating)?,
        strings: AboutPanelStrings,
        showAcknowledgments: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.decorator = decorator
        self.strings = strings
        self.showAcknowledgments = showAcknowledgments
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(AboutWindowKind.about.windowIdentifier)
        window.center()
        window.contentView = NSHostingView(
            rootView: AboutPanelView(strings: strings, showAcknowledgments: showAcknowledgments)
        )
        store.applyCurrentOptions(to: window, for: .about)
        decorator?.applyWindowDecorations(to: window)
        return window
    }

    /// Presents the About window, reapplying the current debug options and
    /// recentering it before ordering it front.
    public func show() {
        let window = managedWindow()
        store.applyCurrentOptions(to: window, for: .about)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

#endif
