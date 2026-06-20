#if canImport(AppKit)
#if DEBUG

public import AppKit

/// Hosts the app's "Startup Appearance Debug" panel in a floating utility window.
///
/// The controller owns only generic AppKit window plumbing: it reuses
/// ``ReleasingWindowController``'s recreate-on-reopen teardown semantics, builds
/// the utility ``NSPanel`` with the fixed `cmux.startupAppearanceDebug` chrome, and
/// decorates the panel through the injected ``WindowDecorating`` seam. The panel's
/// SwiftUI content is irreducibly app-coupled (it drives the live Ghostty startup
/// appearance preview state, reloads the running app's configuration, and reads the
/// app-target `AppearanceSettings`/`GhosttyConfig`), so the app target supplies the
/// content view through the injected `contentProvider`; this package owns no
/// reference to those types or to the application delegate.
///
/// The window title is injected because the legacy app-side title is localized
/// (`debug.startupAppearance.window.title`); resolving `String(localized:)` inside
/// this package would bind to the package bundle (no such key) and silently drop
/// every non-English translation, so the app target resolves it against the app
/// bundle and passes it through.
public final class StartupAppearanceDebugWindowController: ReleasingWindowController {
    private weak var decorator: (any WindowDecorating)?
    private let windowTitle: String
    private let contentProvider: @MainActor () -> NSView

    /// Creates the controller. The panel is built lazily on first presentation.
    ///
    /// - Parameters:
    ///   - decorator: The seam used to normalize the panel's chrome.
    ///   - windowTitle: The localized panel title, resolved app-side against the
    ///     app bundle's catalog.
    ///   - contentProvider: Builds the panel's content view. Invoked on the main
    ///     actor each time the window is (re)created.
    public init(
        decorator: (any WindowDecorating)?,
        windowTitle: String,
        contentProvider: @escaping @MainActor () -> NSView
    ) {
        self.decorator = decorator
        self.windowTitle = windowTitle
        self.contentProvider = contentProvider
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = windowTitle
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.startupAppearanceDebug")
        window.center()
        window.contentView = contentProvider()
        decorator?.applyWindowDecorations(to: window)
        return window
    }

    /// Presents the managed panel, creating it on first use.
    public func show() {
        showManagedWindow()
    }
}

#endif
#endif
