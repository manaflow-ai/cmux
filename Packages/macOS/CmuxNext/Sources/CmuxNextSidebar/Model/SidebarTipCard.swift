import Foundation

/// The "Did you know" card above the footer (BOTTOM-LEFT-CARDS K1): one
/// feature, its benefit and its shortcut. "Try It" sends
/// `SidebarIntent.tryTip(id)`, the x `dismissTip(id)`. The App fills it
/// only when no update card shows (one card at a time). Text arrives
/// localized.
public nonisolated struct SidebarTipCard: Hashable, Sendable {
    public var id: String
    /// "Did you know?".
    public var eyebrow: String
    public var title: String
    public var benefit: String
    /// The feature's shortcut as shown in menus ("⇧⌘P"), nil without one.
    public var shortcut: String?
    public var tryTitle: String
    /// The x's tooltip and VoiceOver label.
    public var dismissLabel: String

    public init(id: String, eyebrow: String, title: String, benefit: String, shortcut: String? = nil,
                tryTitle: String, dismissLabel: String) {
        self.id = id
        self.eyebrow = eyebrow
        self.title = title
        self.benefit = benefit
        self.shortcut = shortcut
        self.tryTitle = tryTitle
        self.dismissLabel = dismissLabel
    }
}
