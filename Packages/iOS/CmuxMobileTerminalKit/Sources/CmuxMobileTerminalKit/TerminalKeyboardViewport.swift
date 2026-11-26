public import CoreGraphics

/// What the keyboard does to the terminal surface while it is up.
///
/// The surface keeps its keyboard-independent viewport; the host slides the
/// whole surface up with the dock. The blank band below the content (blank
/// rows under the cursor plus letterbox slack under a top-pinned grid)
/// absorbs the intrusion first, so a grid whose content fits above the dock
/// does not move. Otherwise the surface slides only the remainder, which
/// leaves the content's last row (the prompt and cursor) on the dock. A
/// scroll-top reveal slides it back down by the reveal.
///
/// `visibleRect` is the viewport minus what the dock covers, in surface
/// coordinates: the sizing chrome (border, hatch, chip) draws inside it so
/// nothing lands under the keyboard or its accessory bar.
public struct TerminalKeyboardViewport: Equatable, Sendable {
    /// Points the surface slides up on screen.
    public let slide: CGFloat
    /// The part of the viewport above the dock, in surface coordinates.
    public let visibleRect: CGRect

    /// - Parameters:
    ///   - viewportRect: The keyboard-independent viewport.
    ///   - intrusion: How far the dock top sits above its keyboard-down seat
    ///     (0 with the keyboard down).
    ///   - blankBelowContent: The blank band below the content, or `nil`
    ///     when it cannot be trusted (alternate screen): nothing absorbs.
    ///   - scrollTopReveal: The scroll-top reveal the pixel-scroll axis
    ///     granted, in points.
    public init(
        viewportRect: CGRect,
        intrusion: CGFloat,
        blankBelowContent: CGFloat?,
        scrollTopReveal: CGFloat = 0
    ) {
        let intrusion = max(0, intrusion)
        let absorbed = TerminalLetterboxGeometry.keyboardAbsorptionSlack(
            blankBelowContent: blankBelowContent,
            intrusion: intrusion
        )
        let slide = max(0, intrusion - absorbed - max(0, scrollTopReveal))
        self.slide = slide
        let covered = min(intrusion - slide, max(0, viewportRect.height))
        visibleRect = CGRect(
            x: viewportRect.minX,
            y: viewportRect.minY,
            width: viewportRect.width,
            height: viewportRect.height - covered
        )
    }
}
