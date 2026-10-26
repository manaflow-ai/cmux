public import AppKit
public import CmuxNextDesignTokens

/// The one entrance and exit every hover card plays: the workspace and tab cards
/// (`HoverCardPanel`) and the sidebar's Update Ready highlights card.
///
/// Lawrence 2026-10-19 (msg 2371): the update card "needs to have the same style, behavior, and
/// styling ... like the hover-on workspace cards. Right now it has a different entry animation".
/// It used to grow out of the card on the `.appear` spring (the menu popup's scale-in,
/// `openPopup`) and shrink back on close; hover cards fade in while they move the last
/// ``entryOffset`` points away from their target on the `.panel` spring, and fade out. Both now
/// call ``enter(_:placement:)`` and ``exit(_:completion:)``, so the two cannot drift apart again.
///
/// ```swift
/// HoverCardMotion.standard.enter(panel, placement: .beside)
/// HoverCardMotion.standard.exit(panel) { panel.orderOut(nil) }
/// ```
public nonisolated struct HoverCardMotion: Equatable, Sendable {
    /// How far a first show moves the card, away from its target, while it fades in.
    public var entryOffset: CGFloat
    /// The spring the entrance slide runs on.
    public var entrySpring: MotionSpring
    /// The fade a first show (or a return during the fade-out) plays.
    public var fadeIn: MotionFade
    /// The fade a hide plays. Opacity only: nothing moves or scales.
    public var fadeOut: MotionFade

    /// - Parameters:
    ///   - entryOffset: Points the card travels on entry.
    ///   - entrySpring: The entrance slide's spring.
    ///   - fadeIn: The entrance fade.
    ///   - fadeOut: The exit fade.
    public init(entryOffset: CGFloat, entrySpring: MotionSpring, fadeIn: MotionFade, fadeOut: MotionFade) {
        self.entryOffset = entryOffset
        self.entrySpring = entrySpring
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    /// The hover card motion (Lawrence 2026-10-18: "proper fade in and translation animation").
    public static let standard = HoverCardMotion(entryOffset: 6, entrySpring: .panel, fadeIn: .fadeIn, fadeOut: .fadeOut)

    /// Where a first show starts from its rest place: toward the target it describes.
    /// - Parameters:
    ///   - placement: Where the card sits relative to its target.
    ///   - leading: For ``HoverCardPlacement/beside`` and ``HoverCardPlacement/besideRow``: the card sits left of its target (a
    ///     sidebar on the right, or no room on the right), so it starts to the right.
    /// - Returns: The translation (points, y up) the entrance slide starts from.
    public func entryVector(for placement: HoverCardPlacement, leading: Bool = false) -> CGVector {
        switch placement {
        case .below: CGVector(dx: 0, dy: entryOffset)
        case .above: CGVector(dx: 0, dy: -entryOffset)
        case .beside, .besideRow: CGVector(dx: leading ? entryOffset : -entryOffset, dy: 0)
        }
    }

    /// A first show: `panel` (placed, ordered out or clear) fades in from clear while its
    /// content slides the last ``entryOffset`` points away from its target. Reduce Motion keeps
    /// only the fade. The panel's content view must be layer-backed (`adoptPopupStyle`), with
    /// at least ``entryOffset`` of clear room around the card (`PopupHostView.travelMargin`).
    /// - Parameters:
    ///   - panel: The card window.
    ///   - placement: Where the card sits relative to its target.
    ///   - leading: The card sits left of its target (see ``entryVector(for:leading:)``).
    @MainActor
    public func enter(_ panel: NSWindow, placement: HoverCardPlacement, leading: Bool = false) {
        Motion.withoutAnimation { panel.animator().alphaValue = 0 }
        panel.orderFront(nil)
        if let layer = panel.contentView?.layer {
            let offset = entryVector(for: placement, leading: leading)
            Motion.hoverCards.set(layer, "sublayerTransform", to: NSValue(caTransform3D: CATransform3DIdentity), spring: entrySpring,
                       from: NSValue(caTransform3D: CATransform3DMakeTranslation(offset.dx, offset.dy, 0)))
        }
        Motion.hoverCards.animateTimed(fadeIn, in: panel.contentView) { panel.animator().alphaValue = 1 }
    }

    /// A return while the card fades out (the pointer came back): it fades back in from the
    /// alpha it reached, where it is, with no second entrance.
    @MainActor
    public func resume(_ panel: NSWindow) {
        Motion.hoverCards.animateTimed(fadeIn, in: panel.contentView) { panel.animator().alphaValue = 1 }
    }

    /// A hide: `panel` fades out where it is (no slide, no scale), then `completion` runs
    /// (which orders it out).
    @MainActor
    public func exit(_ panel: NSWindow, completion: @escaping @MainActor @Sendable () -> Void) {
        Motion.hoverCards.animateTimed(fadeOut, in: panel.contentView, { panel.animator().alphaValue = 0 }, completion: completion)
    }

    /// A card's origin (screen coordinates, y up) next to `anchor`, before the screen clamp:
    /// the same gap and alignment as every hover card (`HoverCardPanel`).
    @MainActor
    public static func origin(for placement: HoverCardPlacement, anchor: CGRect, size: CGSize) -> CGPoint {
        HoverCardPanel.origin(for: placement, anchor: anchor, size: size)
    }
}
