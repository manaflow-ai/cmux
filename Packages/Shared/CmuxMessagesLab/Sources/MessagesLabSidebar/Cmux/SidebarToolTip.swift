// cmux: the host's tooltip for the conversation list's controls. Not a vendored file.
import AppKit

extension NSView {
    /// cmux: the control's tooltip, through the host's ``CmuxSidebarHost/toolTip``; nil or empty: none.
    @MainActor func setSidebarToolTip(_ text: String?) {
        CmuxSidebarView.host.toolTip(self, text?.isEmpty == false ? text : nil)
    }
}
