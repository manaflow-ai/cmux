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
    public var style: AttentionStyle = .blink
    /// nil takes the theme's attention color (`Palette.attention`).
    public var color: ThemeRGB?
    public var width: CGFloat = 2
    public var blinkCount = 2
    /// Seconds the pulse runs before the ring holds steady.
    public var duration: Double = 3
    /// The ring stays after its animation until the notification is dismissed;
    /// false makes it a one-shot flash.
    public var persists = true
    public var showsOnTab = true
    public var showsOnSidebar = true

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
