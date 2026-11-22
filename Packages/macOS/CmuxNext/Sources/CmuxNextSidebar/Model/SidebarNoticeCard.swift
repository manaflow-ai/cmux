import Foundation

/// The shared card for messages to the user above the footer (BOTTOM-LEFT-
/// CARDS K1; Lawrence 2026-10-09): the "Did you know" tip and the update
/// status use it. An optional icon beside the title, an optional small
/// heading above it, one short detail (up to two lines), an optional
/// progress bar, up to two buttons with an optional shortcut beside them,
/// and an x. A button sends `SidebarIntent.noticeAction(card:action:)`, the
/// x `dismissNotice(id)`. The App fills it only when no update card shows
/// (one card at a time). Text arrives localized.
public nonisolated struct SidebarNoticeCard: Hashable, Sendable {
    public enum Progress: Hashable, Sendable {
        /// Work with no measured progress (a moving bar).
        case indeterminate
        /// 0...1.
        case fraction(Double)
    }

    public struct Action: Hashable, Sendable {
        public var id: String
        public var title: String
        /// The call to action (filled); the others are quiet.
        public var prominent: Bool

        public init(id: String, title: String, prominent: Bool = false) {
            self.id = id
            self.title = title
            self.prominent = prominent
        }
    }

    public var id: String
    /// An SF Symbol beside the title, nil for none.
    public var symbol: String?
    /// A small heading above the title ("Did you know?"), nil for none.
    public var eyebrow: String?
    public var title: String
    public var detail: String?
    public var progress: Progress?
    public var actions: [Action]
    /// A shortcut as shown in menus ("⇧⌘P"), beside the buttons.
    public var shortcut: String?
    /// The x's tooltip and VoiceOver label; nil shows no x.
    public var dismissLabel: String?

    public init(id: String, symbol: String? = nil, eyebrow: String? = nil, title: String, detail: String? = nil,
                progress: Progress? = nil, actions: [Action] = [], shortcut: String? = nil, dismissLabel: String? = nil) {
        self.id = id
        self.symbol = symbol
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
        self.progress = progress
        self.actions = actions
        self.shortcut = shortcut
        self.dismissLabel = dismissLabel
    }
}
