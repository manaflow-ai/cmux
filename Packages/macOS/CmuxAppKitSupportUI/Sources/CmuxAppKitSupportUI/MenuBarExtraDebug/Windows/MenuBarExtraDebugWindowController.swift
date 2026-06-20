#if canImport(AppKit)
#if DEBUG

public import AppKit
internal import SwiftUI

/// Hosts the app's "Menu Bar Extra Debug" panel in a floating utility window.
///
/// The controller owns the panel's SwiftUI content directly: it reuses
/// ``ReleasingWindowController``'s recreate-on-reopen teardown semantics, builds
/// the utility ``NSPanel`` with the fixed `cmux.menubarDebug` chrome, mounts
/// ``MenuBarExtraDebugView`` (which edits the package-owned
/// ``MenuBarIconDebugSettings`` defaults), and decorates the panel through the
/// injected ``WindowDecorating`` seam. The view's one app-coupled value, redrawing
/// the live menu-bar icon, is inverted into the injected `refreshMenuBarIcon`
/// closure; this package owns no reference to the application delegate.
public final class MenuBarExtraDebugWindowController: ReleasingWindowController {
    private weak var decorator: (any WindowDecorating)?
    private let refreshMenuBarIcon: @MainActor () -> Void

    /// Creates the controller. The panel is built lazily on first presentation.
    ///
    /// - Parameters:
    ///   - decorator: The seam used to normalize the panel's chrome.
    ///   - refreshMenuBarIcon: Redraws the live menu-bar icon after a tuning
    ///     change. Forwarded into ``MenuBarExtraDebugView``.
    public init(
        decorator: (any WindowDecorating)?,
        refreshMenuBarIcon: @escaping @MainActor () -> Void
    ) {
        self.decorator = decorator
        self.refreshMenuBarIcon = refreshMenuBarIcon
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 430),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Menu Bar Extra Debug"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.menubarDebug")
        window.center()
        window.contentView = NSHostingView(
            rootView: MenuBarExtraDebugView(refreshMenuBarIcon: refreshMenuBarIcon)
        )
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
