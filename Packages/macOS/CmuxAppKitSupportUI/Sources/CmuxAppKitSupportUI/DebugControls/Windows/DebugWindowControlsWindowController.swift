#if canImport(AppKit)
#if DEBUG

public import AppKit

/// Hosts the app's "Debug Window Controls" panel in a floating utility window.
///
/// The controller owns only generic AppKit window plumbing: it reuses
/// ``ReleasingWindowController``'s recreate-on-reopen teardown semantics, builds
/// the utility ``NSPanel`` with the fixed `cmux.debugWindowControls` chrome, and
/// decorates the panel through the injected ``WindowDecorating`` seam. The panel's
/// SwiftUI content is irreducibly app-coupled (it opens roughly a dozen other
/// app-target debug window controllers and reads several app-target settings
/// types), so the app target supplies the content view through the injected
/// `contentProvider`; this package owns no reference to those types or to the
/// application delegate.
public final class DebugWindowControlsWindowController: ReleasingWindowController {
    private weak var decorator: (any WindowDecorating)?
    private let contentProvider: @MainActor () -> NSView

    /// Creates the controller. The panel is built lazily on first presentation.
    ///
    /// - Parameters:
    ///   - decorator: The seam used to normalize the panel's chrome.
    ///   - contentProvider: Builds the panel's content view. Invoked on the main
    ///     actor each time the window is (re)created.
    public init(
        decorator: (any WindowDecorating)?,
        contentProvider: @escaping @MainActor () -> NSView
    ) {
        self.decorator = decorator
        self.contentProvider = contentProvider
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Debug Window Controls"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.debugWindowControls")
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
