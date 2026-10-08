/// An app-only page tab: an internal page (`app-store`, `settings`, ...)
/// this app keeps in a pane's strip, outside the daemon tree.
public struct ControlPageTabInfo: Sendable, Hashable {
    /// The strip id (`local-page:<page>:<uuid>`).
    public var id: String
    /// The internal page id, for example `app-store`.
    public var page: String
    public var title: String
    /// The pane shows this tab.
    public var isSelected: Bool

    public init(id: String, page: String, title: String, isSelected: Bool) {
        self.id = id
        self.page = page
        self.title = title
        self.isSelected = isSelected
    }
}
