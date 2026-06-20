#if canImport(AppKit)

public import AppKit
import SwiftUI

/// Hosts the "Browser Profile Popover" debug panel in a floating utility window.
///
/// The controller owns only generic AppKit window plumbing: it reuses
/// ``ReleasingWindowController``'s recreate-on-reopen teardown, builds the utility
/// ``NSPanel`` with the fixed `cmux.browserProfilePopoverDebug` chrome, and
/// decorates it through the injected ``WindowDecorating`` seam. The panel's
/// SwiftUI content (``BrowserProfilePopoverDebugView``) lives in this package and
/// is pure UI over `UserDefaults`, so this controller needs no app-coupled action
/// seam.
public final class BrowserProfilePopoverDebugWindowController: ReleasingWindowController {
    private weak var decorator: (any WindowDecorating)?

    /// Creates the controller. The panel is built lazily on first presentation.
    ///
    /// - Parameter decorator: The seam used to normalize the panel's chrome.
    public init(decorator: (any WindowDecorating)?) {
        self.decorator = decorator
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 340),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.windows.browserProfilePopover.title",
            defaultValue: "Browser Profile Popover Debug"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.browserProfilePopoverDebug")
        window.center()
        window.contentView = NSHostingView(rootView: BrowserProfilePopoverDebugView())
        decorator?.applyWindowDecorations(to: window)
        return window
    }

    /// Presents the managed panel, creating it on first use.
    public func show() {
        showManagedWindow()
    }
}

#endif
