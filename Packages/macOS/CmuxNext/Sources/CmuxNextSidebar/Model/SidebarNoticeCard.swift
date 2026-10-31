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
        /// Draws as a small switch with its title on the button row's trailing edge instead of a button (the
        /// Tidy Up card's "Always"); flipping it sends the action. A card shows at most one.
        public var isSwitch: Bool

        public init(id: String, title: String, prominent: Bool = false, isSwitch: Bool = false) {
            self.id = id
            self.title = title
            self.prominent = prominent
            self.isSwitch = isSwitch
        }

        /// A menu item from an owner's (id, title) list (the tip's and the update cards' x menus).
        public init(_ item: (id: String, title: String)) {
            self.init(id: item.id, title: item.title)
        }
    }

    public var id: String
    /// An SF Symbol beside the title, nil for none.
    public var symbol: String?
    /// A small heading above the title ("Did you know?"), nil for none.
    public var eyebrow: String?
    public var title: String
    public var detail: String?
    /// Short list lines under the detail (a changelog), one line each.
    public var lines: [String]
    public var progress: Progress?
    public var actions: [Action]
    /// A shortcut as shown in menus ("⇧⌘P"), beside the buttons.
    public var shortcut: String?
    /// The x's tooltip and VoiceOver label; nil shows no x.
    public var dismissLabel: String?
    /// With a title, a small text button with it ("Hide", the found-update
    /// notice, UPDATE-CARD-CLOSE) takes the x's place: one click dismisses at
    /// once (`dismissNotice`), `dismissLabel` is its tooltip and VoiceOver
    /// label, and `dismissMenu` is only on the right-click menu.
    public var dismissTitle: String?
    /// With items, the x opens this menu (the tip's Hide / Mute / Never)
    /// instead of dismissing; an item sends `noticeAction` with its id.
    public var dismissMenu: [Action]
    /// An action the card sends once while it is on screen (a tip marks
    /// itself seen); nil sends none.
    public var shownAction: String?
    /// After `shownAction` was sent: the action sent when this notice leaves
    /// the card (another card took the slot); nil sends none.
    public var hiddenAction: String?
    /// The answer to something the person just asked for (an update check's
    /// progress and result): it takes the bottom-left slot from the Now
    /// Playing and "cmux Updated!" cards, so the answer is never behind them.
    public var userAsked: Bool
    /// Something waits on the person's answer (``SidebarAsks``): the card
    /// takes the slot from every other card, the staged update card too.
    public var awaitsAnswer = false

    public init(id: String, symbol: String? = nil, eyebrow: String? = nil, title: String, detail: String? = nil,
                lines: [String] = [], progress: Progress? = nil, actions: [Action] = [], shortcut: String? = nil, dismissLabel: String? = nil,
                dismissTitle: String? = nil, dismissMenu: [Action] = [], shownAction: String? = nil, hiddenAction: String? = nil, userAsked: Bool = false) {
        self.id = id
        self.symbol = symbol
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
        self.lines = lines
        self.progress = progress
        self.actions = actions
        self.shortcut = shortcut
        self.dismissLabel = dismissLabel
        self.dismissTitle = dismissTitle
        self.dismissMenu = dismissMenu
        self.shownAction = shownAction
        self.hiddenAction = hiddenAction
        self.userAsked = userAsked
    }
}
