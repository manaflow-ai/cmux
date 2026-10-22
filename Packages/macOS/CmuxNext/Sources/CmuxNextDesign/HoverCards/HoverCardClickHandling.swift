public import AppKit

/// A card body with rows a click acts on (the workspace card's tab list, u9696).
///
/// A hover card ignores the mouse, so a click on it reaches the window under it; the coordinator's
/// dismissal monitor offers a left click that lands on the shown card to its body first. When the
/// body takes it the card closes and the click goes no further.
@MainActor
public protocol HoverCardClickHandling: AnyObject {
    /// Acts on a left click at `point` (screen coordinates) on the card.
    ///
    /// - Parameter point: The click's location on screen.
    /// - Returns: True when a row under `point` took the click.
    func hoverCardClick(atScreen point: CGPoint) -> Bool
}
