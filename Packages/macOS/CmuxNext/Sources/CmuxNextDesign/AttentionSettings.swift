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
    /// nil takes the notification blue (`Palette.notificationBlue`, the unread dot's color).
    public var color: ThemeRGB?
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
