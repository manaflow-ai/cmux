#if canImport(AppKit)
#if DEBUG

public import AppKit
import SwiftUI

/// Hosts ``SplitButtonLayoutDebugView`` in a floating utility panel.
///
/// The controller reuses ``ReleasingWindowController``'s recreate-on-reopen
/// teardown semantics and decorates its own panel through the injected
/// ``WindowDecorating`` seam, so this package owns no reference to the
/// application delegate.
public final class SplitButtonLayoutDebugWindowController: ReleasingWindowController {
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
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Split Button Layout"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.splitButtonLayoutDebug")
        window.center()
        window.contentView = NSHostingView(rootView: SplitButtonLayoutDebugView())
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
