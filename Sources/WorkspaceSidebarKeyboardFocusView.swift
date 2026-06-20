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

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if let window,
               AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal() == true {
                return
            }
            window?.makeFirstResponder(nil)
            return
        }
        if forwardKeyDownToFocusedTerminal(with: event) {
            return
        }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return
        }
        super.keyDown(with: event)
    }

    private func forwardKeyDownToFocusedTerminal(with event: NSEvent) -> Bool {
        guard let window,
              AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal() == true,
              let target = window.firstResponder,
              target !== self else {
            return false
        }
        target.keyDown(with: event)
        return true
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        responder === self
    }
}
