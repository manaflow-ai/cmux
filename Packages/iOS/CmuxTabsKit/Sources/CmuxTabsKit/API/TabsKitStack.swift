import Foundation

/// Tabs that belong together, such as the tabs of one Mac pane. In the grid a
/// stack of two or more tabs shows as one card (its front tab) in a liquid
/// glass encasement with a chevron; tapping the chevron morphs the
/// encasement open and shows every tab of the stack in place, and tapping it
/// again folds them back under the front card.
///
/// Return one from `TabsDataSource.stack(of:)` for each tab that is in a
/// stack (the same `id` for all its tabs). A tab alone in its stack, or a
/// pinned tab, shows as a plain card.
public struct TabsKitStack: Hashable, Sendable {
    /// Identifies the stack: the same for every tab in it (a pane's id).
    public var id: String
    /// What the stack is called, for VoiceOver ("Pane 2").
    public var title: String
    /// The tab a folded stack shows when the active tab is not in it (the
    /// tab the pane shows on the Mac). Nil: the stack's first tab.
    public var frontTabID: TabsKitTab.ID?

    public init(id: String, title: String, frontTabID: TabsKitTab.ID? = nil) {
        self.id = id
        self.title = title
        self.frontTabID = frontTabID
    }
}
