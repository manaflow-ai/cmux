#if canImport(AppKit)

public import AppKit
import SwiftUI

/// Hosts the "Browser Import Hint" debug panel in a floating utility window.
///
/// The controller owns only generic AppKit window plumbing: it reuses
/// ``ReleasingWindowController``'s recreate-on-reopen teardown, builds the utility
/// ``NSPanel`` with the fixed `cmux.browserImportHintDebug` chrome, and decorates
/// it through the injected ``WindowDecorating`` seam. The panel's SwiftUI content
/// (``BrowserImportHintDebugView``) lives in this package; its quick-action
/// buttons reach the running app only through the injected ``BrowserDebugContext``
/// seam, so this package owns no reference to the application delegate or the
/// import coordinator.
public final class BrowserImportHintDebugWindowController: ReleasingWindowController {
    private weak var decorator: (any WindowDecorating)?
    private weak var context: (any BrowserDebugContext)?

    /// Creates the controller. The panel is built lazily on first presentation.
    ///
    /// - Parameters:
    ///   - decorator: The seam used to normalize the panel's chrome.
    ///   - context: The seam backing the panel's quick-action buttons.
    public init(
        decorator: (any WindowDecorating)?,
        context: (any BrowserDebugContext)?
    ) {
        self.decorator = decorator
        self.context = context
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Browser Import Hint Debug"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.browserImportHintDebug")
        window.center()
        window.contentView = NSHostingView(rootView: BrowserImportHintDebugView(context: context))
        decorator?.applyWindowDecorations(to: window)
        return window
    }

    /// Presents the managed panel, creating it on first use.
    public func show() {
        showManagedWindow()
    }
}

#endif
