public import CoreGraphics

/// What a ``CmuxToastStyle`` draws: the knobs ``CmuxToastView``, ``CmuxToastOverlayHost`` and
/// ``CmuxToastMotion`` read. Two styles never have the same look.
public nonisolated struct CmuxToastLook: Hashable, Sendable {
    /// The surface's outline.
    public enum Shape: String, Sendable, Hashable {
        /// The toast role's corner radius (``SurfaceRole/toast``).
        case rounded
        /// Round ends: the corner radius is half the toast's height.
        case capsule
    }

    /// The surface's outline.
    public var shape: Shape = .rounded
    /// The glass the toast draws on; nil: the one Debug Settings > Toasts picks (``CmuxToastTunables/glass``).
    public var glass: CmuxToastGlass?
    /// An opaque surface in the theme's popup fill instead of glass, as under Reduce Transparency.
    public var solid = false
    /// The caption font and tighter padding: one short line.
    public var compact = false
    /// A leading SF Symbol in the tone's color (``CmuxToastTone``; an Undo shows its arrow).
    public var showsIcon = false
    /// The detail as a second line under the message (else it is the message's tooltip).
    public var showsDetailLine = false
    /// The primary action as a button filled with the accent, not a text button.
    public var fillsAction = false
    /// The primary action as a small button filled with the toast's ink (dark on light glass, light on dark).
    public var inkAction = false
    /// A leading mark in the tone's color for a success, warning or error; plain news shows none.
    public var marksTone = false
    /// The close button shows only while the pointer is on the toast (VoiceOver and the keyboard still reach it).
    public var closeOnHover = false
    /// A ring around the close button that empties over the toast's time.
    public var showsCountdown = false
    /// A bar in the tone's color along the leading edge.
    public var accentBar = false
    /// Where the toast rests.
    public var placement: CmuxToastPlacement = .bottomCenter
    /// How it arrives and leaves.
    public var entrance: CmuxToastEntrance = .rise
    /// A rounded surface's corner (``Corner``); a capsule's is always half its height.
    public var corner: Corner = .concentric

    /// A rounded toast's corner. Its buttons stay concentric inside it (the corner less the padding), as every
    /// container of buttons (``ConcentricContainer``). The Toast Playground's Corner row draws each (Leo,
    /// 2026-11-22, on the one-line Undo toast: "im not sure if it should be that rounded. what's our design
    /// language?").
    public enum Corner: Hashable, Sendable {
        /// The button corner plus the padding: 16 pt on a 38 pt one-line toast, which reads as a pill.
        case concentric
        /// A corner of this many points before the interface scale (12: the card and composer corner of
        /// design/grid.md and `--ds-radius-xl`; 8: the popup corner, `--ds-radius-popup`).
        case points(CGFloat)
        /// The toast surface role's corner (``SurfaceRole/toast``, the one concentric corner rule's outer
        /// radius): "a rounded rect, never a capsule, even on one line".
        case surfaceRole
    }

    public init() {}
}
