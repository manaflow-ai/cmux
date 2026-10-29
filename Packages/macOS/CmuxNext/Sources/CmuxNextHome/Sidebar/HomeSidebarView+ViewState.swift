public import AppKit

/// What a discarded Home records of its list and puts back when it is built again:
/// the search the person typed and where the list was scrolled.
extension HomeSidebarView {
    /// The search field's text.
    public var searchQuery: String { list.searchQuery }

    /// Shows `query` in the search field and filters the list by it, as typed.
    public func setSearch(_ query: String) { list.setSearch(query) }

    /// The list's visible origin (its scroll position).
    public var scrollOrigin: CGPoint { list.scrollView.contentView.bounds.origin }

    /// Scrolls the list to `origin`, clamped to its content.
    public func scroll(to origin: CGPoint) { list.scrollView.documentView?.scroll(origin) }
}
