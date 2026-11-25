import AppKit

extension HomeNativeTranscriptView {
    /// The transcript draws as seen only in the key window while that window is visible.
    func windowStateChanged() {
        transcript.isVisibleToUser = window.map { $0.isKeyWindow && $0.occlusionState.contains(.visible) } ?? false
        // The message box took the keyboard before its window turned key (a launch whose window keys late): AppKit does not
        // tell it again, so tell the host now, for its "window takes keys" launch mark (`window_usable`, marked once).
        if let window, window.isKeyWindow, let field = window.firstResponder as? NSTextView, field.isEditable, field.isDescendant(of: transcript) {
            transcript.onComposerFocused?(field)
        }
    }
}
