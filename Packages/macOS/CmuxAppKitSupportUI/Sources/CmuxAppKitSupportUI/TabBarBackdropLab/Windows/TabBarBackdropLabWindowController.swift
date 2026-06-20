#if canImport(AppKit)

public import AppKit

/// Hosts the app's "Tab Bar Backdrop Lab" panel in a floating, transparent window.
///
/// The controller owns only generic AppKit window plumbing: it reuses
/// ``ReleasingWindowController``'s recreate-on-reopen teardown semantics and builds
/// the borderless-style ``NSPanel`` with the fixed `cmux.tabBarBackdropLab` chrome
/// (hidden title, transparent titlebar, clear background, floating level). The
/// panel's SwiftUI content is irreducibly app-coupled (the lab samples live
/// `GhosttyApp`/`Workspace` Bonsplit backdrop tuning and renders real `Bonsplit`
/// tab bars), so the app target supplies the content view through the injected
/// `contentProvider`; this package owns no reference to those types.
public final class TabBarBackdropLabWindowController: ReleasingWindowController {
    private let contentProvider: @MainActor () -> NSView

    /// Creates the controller. The panel is built lazily on first presentation.
    ///
    /// - Parameter contentProvider: Builds the panel's content view. Invoked on the
    ///   main actor each time the window is (re)created.
    public init(contentProvider: @escaping @MainActor () -> NSView) {
        self.contentProvider = contentProvider
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1040),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.tabBarBackdropLab.title", defaultValue: "Tab Bar Backdrop Lab")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.level = .floating
        window.identifier = NSUserInterfaceItemIdentifier("cmux.tabBarBackdropLab")
        window.center()

        let hostingView = contentProvider()
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hostingView

        return window
    }

    /// Presents the managed panel, creating it on first use.
    public func show() {
        showManagedWindow(orderFrontRegardless: true)
    }
}

#endif
