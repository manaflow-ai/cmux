import AppKit

/// AppKit focus endpoint for the SwiftUI Source Control panel.
final class SourceControlKeyboardFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerSourceControlHost(self)
    }

    override func layout() {
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) else {
            return super.performKeyEquivalent(with: event)
        }
        _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: mode,
            focusFirstItem: true,
            preferredWindow: window
        )
        return true
    }

    override func keyDown(with event: NSEvent) {
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return
        }
        super.keyDown(with: event)
    }

    @discardableResult
    func focusFirstItemFromCoordinator() -> Bool {
        focusHostFromCoordinator()
    }

    func focusHostFromCoordinator() -> Bool {
        guard let window else { return false }
        return window.makeFirstResponder(self)
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        responder === self
    }
}
