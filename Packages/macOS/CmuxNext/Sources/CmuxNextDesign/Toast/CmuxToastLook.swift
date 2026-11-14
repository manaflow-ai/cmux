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

    public init() {}
}
