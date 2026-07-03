import AppKit

extension GhosttyNSView {
    func reassertSurfaceFocusForPhysicalInput(reason: String) {
        guard let terminalSurface else { return }
#if DEBUG
        let wasFocused = terminalSurface.debugDesiredFocusState()
#endif
        terminalSurface.setFocus(true)
#if DEBUG
        guard !wasFocused else { return }
        let ownsFirstResponder: Bool = {
            guard let firstResponder = window?.firstResponder as? NSView else { return false }
            return firstResponder === self || firstResponder.isDescendant(of: self)
        }()
        cmuxDebugLog(
            "focus.input.reassert surface=\(terminalSurface.id.uuidString.prefix(5)) " +
            "reason=\(reason) keyWindow=\(window?.isKeyWindow == true ? 1 : 0) " +
            "firstResponder=\(ownsFirstResponder ? 1 : 0) hidden=\(isHiddenOrHasHiddenAncestor ? 1 : 0) " +
            "frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height))"
        )
#endif
    }
}
