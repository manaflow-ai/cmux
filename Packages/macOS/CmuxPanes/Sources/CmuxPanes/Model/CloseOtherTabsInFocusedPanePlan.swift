public import Foundation

/// The derived close-target set for the "Close Other Tabs in Focused Pane"
/// command: the unpinned panels in the focused pane other than its selected
/// tab, plus their display titles for the confirmation prompt (mirrors the
/// legacy `TabManager.CloseOtherTabsInFocusedPanePlan`).
///
/// The legacy plan carried a live `Workspace` reference so the caller could
/// mutate it after confirming. This value type carries only the derived data
/// (`panelIds` and `titles`); the app-side caller keeps the live workspace it
/// resolved before building the plan and drives `markCloseHistoryEligible` /
/// `closePanel` itself, so the close mutation and its `NSAlert` confirmation
/// stay app-side while the derivation lives in this package.
public struct CloseOtherTabsInFocusedPanePlan: Equatable, Sendable {
    /// The panel ids to close (focused-pane tabs other than the selected tab,
    /// excluding pinned panels), in tab order.
    public let panelIds: [UUID]

    /// The display titles of the panels in ``panelIds``, index-aligned, for the
    /// confirmation prompt.
    public let titles: [String]

    /// Creates a plan.
    public init(panelIds: [UUID], titles: [String]) {
        self.panelIds = panelIds
        self.titles = titles
    }
}
