import AppKit

/// Keyboard-focus host for the Snippets sidebar. The focus coordinator
/// hands the tool focus through this view: "first item" means the search
/// field; the host itself is the fallback responder. Ownership checks let
/// the coordinator treat the search field as sidebar focus so terminal focus
/// is restored correctly when the sidebar hides.
final class SnippetsKeyboardFocusView: NSView {
    var focusSearchField: (() -> Bool)?
    var ownsResponder: ((NSResponder) -> Bool)?
    /// Set by `SnippetsSidebarFocusBridge` after its first lookup.
    weak var cachedSearchField: SidebarSearchField?
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerSnippetsHost(self)
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === self { return true }
        return ownsResponder?(responder) == true
    }

    func focusFirstItemFromCoordinator() {
        _ = focusSearchField?()
    }

    func focusHostFromCoordinator() -> Bool {
        focusSearchField?() == true || window?.makeFirstResponder(self) == true
    }
}
