import AppKit
import CmuxNextDesign
import CmuxNextSidebar

// `sidebar.style` = rail (plans/cmux-next/minimal-sidebar.md): the content and the title sit beside
// the rail (`SidebarModel.contentInset`), measured from the window edge rather than from the sidebar,
// so the rail's full sidebar opens over them and no terminal resizes. The standard style frames them
// beside the sidebar (`WindowRootLayout`).
extension WindowRootView {
    /// The rail's inset of the content and the title from the sidebar's window edge; nil in the
    /// standard style.
    var railContentInset: CGFloat? {
        sidebar.model.style == .rail ? sidebar.model.contentInset : nil
    }

    /// A style, side, presentation or gutter change: the next layout pass frames the content and
    /// the title for it.
    func applySidebarRail() {
        needsLayout = true // invalidate: the rail inset or the style changed (the placement stream emits changes only).
    }
}
