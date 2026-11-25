// cmux: the host's tooltip for the conversation list's controls. Not a vendored file.
import AppKit

extension NSView {
    /// cmux: the control's tooltip, through the host's ``CmuxSidebarHost/showToolTip``; nil or empty: none. Callable from
    /// the list's nonisolated controllers (as `toolTip` was); off the main thread it sets nothing.
    func setSidebarToolTip(_ text: String?) {
        SidebarToolTipSeam(view: self).set(text)
    }
}
