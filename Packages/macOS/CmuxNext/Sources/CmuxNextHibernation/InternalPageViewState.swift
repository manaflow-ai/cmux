package import CoreGraphics

/// What an internal page tab shows that its rebuilt view shows again: taken right before the view
/// is released, given back before the tab's next view is made.
package nonisolated struct InternalPageViewState: Equatable, Sendable {
    /// The page's route (a React page's `#/…` fragment).
    package var route: String?
    /// The content's scroll offset.
    package var scroll: CGPoint?
    /// The text in the page's search field.
    package var search: String?
    /// The selected items' ids.
    package var selection: [String]
    /// Page-specific values (the Task Manager's sort and top row).
    package var fields: [String: String]

    package init(route: String? = nil, scroll: CGPoint? = nil, search: String? = nil, selection: [String] = [],
                 fields: [String: String] = [:]) {
        self.route = route
        self.scroll = scroll
        self.search = search
        self.selection = selection
        self.fields = fields
    }
}
