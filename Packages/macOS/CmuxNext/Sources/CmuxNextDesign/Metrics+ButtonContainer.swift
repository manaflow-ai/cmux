public import CoreGraphics
public import CmuxNextDesignTokens

/// Containers that hold buttons round from the button corner (Lawrence 2026-11-15: "all dialogs needs
/// concentric padding with buttons inside").
public extension Metrics {
    /// A rounded container (a dialog card, a toast, a hint, a banner) around buttons `padding` in from its
    /// edges: the buttons round by ``buttonCornerRadius`` (every button rounds as a tab) and the container by
    /// that plus `padding`, so the curves share a center at every density. Read the container's corner,
    /// the buttons' hover shape and the text's leading inset from the one value.
    ///
    /// ```swift
    /// let card = Metrics.buttonContainer(padding: 16)
    /// glass.cornerRadius = card.outerRadius           // 20 at the default density
    /// ChromeHover(button, cornerRadius: card.childRadius)
    /// ```
    /// - Parameter padding: Points from the container's edge to a button, the same on the top, the bottom and
    ///   the near side.
    /// - Returns: The container's concentric geometry.
    static func buttonContainer(padding: CGFloat) -> ConcentricContainer {
        ConcentricContainer(childRadius: buttonCornerRadius, padding: padding)
    }

    /// A close x (or another control) in the corner of a card or a toast rounded by `outerRadius`, concentric
    /// with it (Lawrence 2026-11-15: the Updated card's x was not concentric with the card's corner): the same
    /// padding from the top and the side, the x's hover shape the corner less it, at least ``space1`` in.
    ///
    /// ```swift
    /// let x = Metrics.cornerControl(outerRadius: surface.cornerRadius, side: 16)
    /// closeButton.frame = x.topTrailingFrame(side: 16, in: bounds, flipped: isFlipped)
    /// closeButton.concentricRadius = x.childRadius
    /// ```
    /// - Parameter outerRadius: The card's corner.
    /// - Parameter side: The control's side.
    /// - Returns: The control's concentric geometry in the corner.
    static func cornerControl(outerRadius: CGFloat, side: CGFloat) -> ConcentricContainer {
        .cornerControl(outerRadius: outerRadius, side: side, minimumPadding: space1)
    }
}
