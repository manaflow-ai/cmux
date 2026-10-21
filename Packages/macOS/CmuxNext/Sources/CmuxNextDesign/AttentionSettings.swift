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
    /// How the ring draws (`notifications.attention.ringStyle`): `glow`, a stroke with a soft glow
    /// as classic's; `ring`, the stroke alone; `none`, no ring at all (the tab and the sidebar
    /// row still show the unread mark).
    public var ringStyle: FocusRingStyle = .glow
    /// Terminal and other panes ring for their notifications (`notifications.attention.terminals`).
    public var ringsTerminals = true
    /// Agent chat panes ring, and flash out, when a turn ends or a notification arrives there
    /// (`notifications.attention.agentChats`). Off by default (Leo, 2026-10-21: no blinky on turn
    /// end for the GUI): a turn that ends in a shown chat is read at once.
    public var ringsAgentChats = false
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

    public init() {}

    /// Whether any ring draws: a ring style and an arrival style other than none.
    public var drawsRing: Bool { style != .none && ringStyle != .none }

    /// Whether a pane showing an agent chat (`agentChat`) or anything else rings.
    public func rings(agentChat: Bool) -> Bool {
        drawsRing && (agentChat ? ringsAgentChats : ringsTerminals)
    }

    public static let widthRange: ClosedRange<CGFloat> = 0.5...8
    public static let blinkRange: ClosedRange<Int> = 1...10
    public static let durationRange: ClosedRange<Double> = 0.3...30
}

/// One pane's attention mark as the layout draws it.
public nonisolated struct AttentionMark: Hashable, Sendable {
    /// Per-source color override; nil uses `AttentionSettings.color`.
    public var color: ThemeRGB?
    /// Changes with every new notification, so the animation restarts.
    public var generation: UInt64

    public init(color: ThemeRGB? = nil, generation: UInt64) {
        self.color = color
        self.generation = generation
    }
}
