public import AppKit
import MessagesLabSidebar

/// The list's view state that no store keeps: what the person searched for and where they
/// scrolled. A Home view made again after a discard puts both back (`memoryDiscardInternalPages`).
extension HomeSidebarView {
    /// The search field's text. Setting it searches as typing does, and the header opens the
    /// search when it holds text.
    public var searchText: String {
        get { list.searchQuery }
        set {
            list.search(newValue)
            list.headerView.needsLayout = true
        }
    }

    /// Where the list is scrolled to: the top-left of what shows.
    public var scrollOrigin: CGPoint {
        get { list.scrollView.documentVisibleRect.origin }
        set {
            list.scrollView.contentView.scroll(to: newValue)
            list.scrollView.reflectScrolledClipView(list.scrollView.contentView)
        }
    }
}
