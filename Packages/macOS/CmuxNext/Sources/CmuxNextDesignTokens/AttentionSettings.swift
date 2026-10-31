public import CoreGraphics

/// How a pane that needs attention (an unread notification) is marked
/// (`notifications.attention.style`).
public nonisolated enum AttentionStyle: String, Hashable, Sendable, CaseIterable {
    case none
    /// A ring that stays until the notification is dismissed.
    case steady
    /// The ring breathes for `duration`, then stays.
    case pulse
    /// The ring blinks `blinkCount` times, then stays.
    case blink
}

/// `notifications.attention.*` in cmux.json: the pane attention ring and
/// whether the tab and the sidebar row show the unread mark too.
public nonisolated struct AttentionSettings: Hashable, Sendable {
    /// `steady` (Austin, 2026-10-20): a blue ring just appears, as in cmux classic; the blink
    /// plays when the person goes into the pane and the ring goes away
    /// (`MotionGate.attentionDismissAnimation`).
    public var style: AttentionStyle = .steady
    /// nil takes the theme accent (`AttentionHighlightLook.defaultColor`): never a fixed blue
    /// (Leo, 2026-10-21: "if we have any kind of blinky, it should be themed/customizable").
    public var color: ThemeRGB?
    /// How a terminal (or any pane but an agent chat) rings (`notifications.attention.terminals`):
    /// `glow`, a stroke with a soft glow as classic's (default); `ring`, the stroke alone; `none`,
    /// no ring (the tab and the sidebar row still show the unread mark).
    public var terminalRing: FocusRingStyle = .glow
    /// How an agent chat's pane rings when its turn ends (`notifications.attention.agentChats`).
    /// `none` by default (Leo, 2026-10-21: no blinky on turn end for the GUI; cmuxterm-hq#2959):
    /// a turn that ends in a shown chat is read at once. On, `ring` is the recommended look.
    public var agentChatRing: FocusRingStyle = .none
    /// The agent chat ring's flashes as it goes (`notifications.attention.agentChatBlinkCount`):
    /// one (cmuxterm-hq#2959); `blinkCount` is the terminal's.
    public var agentChatBlinkCount = 1
    /// The look of the pane being drawn, which `surface(agentChat:)` sets from the two above.
    public var ringStyle: FocusRingStyle = .glow
    public var width: CGFloat = 2
    public var blinkCount = 2
    /// Seconds the pulse runs before the ring holds steady.
    public var duration: Double = 3
    /// The ring stays after its animation until the notification is dismissed;
    /// false makes it a one-shot flash.
    public var persists = true
    /// Going into an unread pane (a click, a key, opening it) flashes its ring
    /// as it goes, as classic's dismiss flash did (`notifications.attention.flash`,
    /// classic `notifications.paneFlash`).
    public var flashesOnRead = true
    /// A key typed into the pane flashes it too (`notifications.attention.flashOnTyping`,
    /// classic `notifications.paneFlashOnTyping`).
    public var flashesOnTyping = true
    public var showsOnTab = true
    public var showsOnSidebar = true
    /// A notification for a pane the user is not looking at moves its
    /// workspace to the top of the unpinned rows (classic's
    /// `app.reorderOnNotification`). Off by default: the sidebar keeps the
    /// order the user made and shows attention as a badge (Leo 2026-10-20).
    public var movesToTop = false
    /// An agent's finished turn (`agent.turn.completed`) for a pane the user is not
    /// looking at moves its workspace to the top, as `movesToTop` does for every
    /// notification (`notifications.attention.moveToTopOnAgentFinish`, cmux#31513).
    /// Off by default, like `movesToTop`.
    public var movesToTopOnAgentFinish = false

    public init() {}

    /// Whether a notification moves its workspace to the top: every one with `movesToTop`,
    /// an agent's finished turn (`finishedTurn`) with `movesToTopOnAgentFinish` too.
    public func movesToTop(finishedTurn: Bool) -> Bool { movesToTop || finishedTurn && movesToTopOnAgentFinish }

    /// Whether the pane being drawn shows a ring: its look and the arrival style are not none.
    public var drawsRing: Bool { style != .none && ringStyle != .none }

    /// The settings one pane draws with: an agent chat's look and flash count, or a terminal's.
    public func surface(agentChat: Bool) -> AttentionSettings {
        var settings = self
        settings.ringStyle = agentChat ? agentChatRing : terminalRing
        if agentChat { settings.blinkCount = agentChatBlinkCount }
        return settings
    }

    /// Whether a pane showing an agent chat (`agentChat`) or anything else rings.
    public func rings(agentChat: Bool) -> Bool { surface(agentChat: agentChat).drawsRing }

    public static let widthRange: ClosedRange<CGFloat> = 0.5...8
    public static let blinkRange: ClosedRange<Int> = 1...10
    public static let durationRange: ClosedRange<Double> = 0.3...30
}

/// One pane's attention mark as the layout draws it.
public nonisolated struct AttentionMark: Hashable, Sendable {
    /// Per-source color override; nil uses `AttentionSettings.color`.
    public var color: ThemeRGB?
    /// The newest event's id. A ring that already shows stays as it is when it changes: attention
    /// is on or off, not a queue (https://github.com/manaflow-ai/cmux/issues/25662).
    public var generation: UInt64
    /// The pane shows an agent chat: it draws with `AttentionSettings.surface(agentChat: true)`.
    public var agentChat: Bool
    /// The ring arrives at rest with no pulse: one of a burst of turn ends (cmuxterm-hq#2959).
    public var quiet: Bool

    public init(color: ThemeRGB? = nil, generation: UInt64, agentChat: Bool = false, quiet: Bool = false) {
        self.color = color
        self.generation = generation
        self.agentChat = agentChat
        self.quiet = quiet
    }
}
