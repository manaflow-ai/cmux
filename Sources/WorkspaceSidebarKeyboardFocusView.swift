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
            if restoreFocusedMainPanelFocus() {
                return
            }
            window?.makeFirstResponder(nil)
            return
        }
        if forwardKeyDownToFocusedMainPanel(with: event) {
            return
        }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            window?.makeFirstResponder(nil)
            return
        }
        super.keyDown(with: event)
    }

    private func restoreFocusedMainPanelFocus() -> Bool {
        guard let window else { return false }
        return AppDelegate.shared?.keyboardFocusCoordinator(for: window)?
            .restoreFocusedPanelFocusFromWorkspaceSidebarIfNeeded(currentResponder: self) == true
    }

    private func forwardKeyDownToFocusedMainPanel(with event: NSEvent) -> Bool {
        guard let window,
              restoreFocusedMainPanelFocus(),
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
