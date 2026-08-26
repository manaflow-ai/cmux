public import CoreGraphics

/// The Auto Layout endpoints for one keyboard transition leg.
///
/// The host animates exactly two constraint constants per keyboard leg — the
/// dock-bottom offset and the render wrapper's bottom offset — inside a single
/// animated layout pass. Every other moving edge (clip bottom, toolbar,
/// composer band) derives from those in the same pass, so the bars and the
/// terminal boundary share one timeline by construction. This type is the pure
/// arithmetic from notification-derived inputs to those two constants, plus
/// the derived keyboard-top target the debug probe reports.
public struct TerminalKeyboardDockEndpoints: Equatable, Sendable {
    /// Constant for `dock.bottom = host.bottom + c`: the negated bottom
    /// reservation (keyboard overlap, or the safe-area fallback).
    public let dockBottomConstant: CGFloat

    /// Where the dock's bottom edge (the keyboard's top edge) settles, in host
    /// coordinates. Reported by the dock probe as `keyboardDockTargetTop`.
    public let keyboardTopTarget: CGFloat

    /// Constant for `renderWrapper.bottom = host.bottom + c`: how far the
    /// rendered content's bottom edge must travel from its current model
    /// position to its settled position. Zero when the settled layout keeps
    /// the render where it already is (keyboard dismissal holding the top row,
    /// or blank rows absorbing the whole keyboard intrusion).
    public let presentationBottomConstant: CGFloat

    /// The settled render-bottom edge, folded into the renderer model when the
    /// transition completes so the fold is a visual no-op.
    public let settledRenderBottom: CGFloat

    /// - Parameters:
    ///   - boundsMaxY: The host bounds bottom edge in points.
    ///   - bottomReservation: The settled bottom reservation (keyboard overlap
    ///     when up, safe-area fallback when down; chrome-hidden already applied).
    ///   - settledRenderBottom: The render-bottom edge the first settled layout
    ///     pass will compute (`TerminalLetterboxGeometry.renderPinnedBottomEdge`
    ///     through the viewport snapshot), so the animated leg lands exactly
    ///     where the post-transition layout would put it — no settle snap.
    ///   - modelRenderBottom: The render-bottom edge currently in the renderer
    ///     model (frozen for the duration of the transition).
    public init(
        boundsMaxY: CGFloat,
        bottomReservation: CGFloat,
        settledRenderBottom: CGFloat,
        modelRenderBottom: CGFloat
    ) {
        let reservation = max(0, bottomReservation)
        dockBottomConstant = -reservation
        keyboardTopTarget = max(0, boundsMaxY - reservation)
        self.settledRenderBottom = settledRenderBottom
        presentationBottomConstant = settledRenderBottom - modelRenderBottom
    }
}
