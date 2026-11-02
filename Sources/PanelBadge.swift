import Bonsplit
import CmuxCore

/// A tab's badge: text in front of its title, and an optional color Bonsplit
/// uses to tint the tab and draw a strip along its top edge.
struct PanelBadge: Equatable, Sendable {
    /// The text in front of the title.
    let text: PanelBadgeText
    /// The tab's marking color, if any.
    let color: TabColor?

    /// Puts the badge text in front of a title: `<badge> <title>`.
    func titled(_ title: String) -> String {
        text.titled(title)
    }
}
