#if canImport(AppKit)

public import AppKit

/// Hosts the ``SidebarDebugView`` editor in a floating utility panel.
///
/// The controller owns generic AppKit window plumbing: it reuses
/// ``ReleasingWindowController``'s recreate-on-reopen teardown and builds the
/// fixed `cmux.sidebarDebug` utility panel. The editor's content view is supplied
/// through the injected `contentProvider` because it depends on app-resolved
/// values (the live accent color and localized indicator-style names), and the
/// panel chrome is normalized through the ``WindowDecorating`` seam.
public final class SidebarDebugWindowController: ReleasingWindowController {
    private let contentProvider: @MainActor () -> NSView
    private weak var decorator: (any WindowDecorating)?

    /// Creates the controller. The panel is built lazily on first presentation.
    ///
    /// - Parameters:
    ///   - decorator: The seam used to decorate the editor panel itself.
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
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Sidebar Debug"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.sidebarDebug")
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
