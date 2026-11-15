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
    /// glass.cornerRadius = card.outerRadius           // 24 at the default density
    /// ChromeHover(button, cornerRadius: card.childRadius)
    /// ```
    /// - Parameter padding: Points from the container's edge to a button, the same on the top, the bottom and
    ///   the near side.
    /// - Returns: The container's concentric geometry.
    static func buttonContainer(padding: CGFloat) -> ConcentricContainer {
        ConcentricContainer(childRadius: buttonCornerRadius, padding: padding)
    }
}
