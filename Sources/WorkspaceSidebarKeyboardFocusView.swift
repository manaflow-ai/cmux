import AppKit

@MainActor
final class WorkspaceSidebarKeyboardFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerWorkspaceSidebarHost(self)
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        responder === self
    }
}
