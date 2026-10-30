import AppKit
import CmuxNextCompat

/// A resize in flight: the card laid out at the larger of its two sizes, shown through a mask
/// that grows or shrinks from the last card's size to the next one's.
@MainActor
struct HoverCardMorph {
    /// The mask over the card's surface (rounded like the card).
    let mask: CALayer
    /// The corner that stays on the target while the size changes (unit coordinates, y up).
    let corner: CGPoint
    /// Bumped per morph, so a finished morph's completion leaves a newer one alone.
    let generation: Int
}

// One card that morphs (Lawrence 2026-10-20: "Ideally it's the same card and we animate the
// resizing so that only one card ... appears at any point in time ... We do the translation
// thing, like the `translate-y` thing"). A retarget to a card of another size (a workspace card
// to the Update Ready highlights, a short workspace card to a long one) keeps the one card: it
// translates from where it is drawn to its new place (`slide(from:)`, the `.panel` spring) while
// its surface and shadow resize on the same spring, from the last card's size to the next one's,
// about the corner that stays on the target. The content crossfades inside. Reduce Motion (or
// speed off, or a sleeping display) changes the size at once.
//
// How: the card is laid out at the larger of the two sizes, the body pinned to the fixed corner
// at its own size, and a rounded mask shows the part the animation is at; the shadow's path and
// its cutout follow the same spring. When the spring settles the card is laid out at rest again.
extension HoverCardPanel {
    private static var morphGeneration = 0

    /// The card's rest frame at the size a morph in flight shows now.
    var presentedSize: CGRect {
        guard let activeMorph else { return cardFrame }
        let shown = (activeMorph.mask.presentation() ?? activeMorph.mask).bounds.size
        let rest = restCardFrame
        let x = activeMorph.corner.x == 0 ? rest.minX : rest.maxX - shown.width
        let y = activeMorph.corner.y == 0 ? rest.minY : rest.maxY - shown.height
        return CGRect(x: x, y: y, width: shown.width, height: shown.height)
    }

    /// The corner of the card that stays on its target while it resizes (unit, y up).
    private var fixedCorner: CGPoint {
        switch restingPlacement {
        case .above: CGPoint(x: isLeading ? 1 : 0, y: 0)
        case .below, .beside: CGPoint(x: isLeading ? 1 : 0, y: 1)
        // The top stays fixed (on the row's top, or below the escape slot in the Debug middle layout);
        // the bottom when the middle layout flipped the card above the row's middle.
        case .besideRow: CGPoint(x: isLeading ? 1 : 0, y: escapeGeometry.map { $0.card.minY >= $0.anchor.minY } == true ? 0 : 1)
        }
    }

    /// Morphs the card from `previous` (screen, as drawn before this show) to its rest frame:
    /// a translation and a resize on one spring. Returns false (nothing done) when the sizes
    /// match, or when motion is off; the caller then slides or places it at once.
    @discardableResult
    func morph(from previous: CGRect) -> Bool {
        let rest = cardFrame
        guard abs(previous.width - rest.width) > 0.5 || abs(previous.height - rest.height) > 0.5 else { return false }
        // The same gate as the slide it runs with (`Motion.set`): Reduce Motion or speed off resize at once.
        guard Motion.hoverCards.animatesMovement, let host, let body, let glassLayer = glass.layer else { return false }
        let corner = fixedCorner
        // The larger card the mask shows a part of, about the fixed corner.
        let big = CGSize(width: max(previous.width, rest.width), height: max(previous.height, rest.height))
        let bigFrame = CGRect(x: corner.x == 0 ? rest.minX : rest.maxX - big.width,
                              y: corner.y == 0 ? rest.minY : rest.maxY - big.height, width: big.width, height: big.height)
        // Where the fixed corner was, from where it goes: the translation the card slides from.
        let from = CGPoint(x: corner.x == 0 ? previous.minX : previous.maxX, y: corner.y == 0 ? previous.minY : previous.maxY)
        let to = CGPoint(x: corner.x == 0 ? rest.minX : rest.maxX, y: corner.y == 0 ? rest.minY : rest.maxY)
        let offset = CGVector(dx: from.x - to.x, dy: from.y - to.y)

        // The body keeps its own size, pinned to the fixed corner, while the card is larger.
        sizeConstraints[0].constant = rest.width
        sizeConstraints[1].constant = rest.height
        let loose = corner.x == 0 ? edgeConstraints[3] : edgeConstraints[2]
        let looseY = corner.y == 0 ? edgeConstraints[0] : edgeConstraints[1]
        NSLayoutConstraint.deactivate([loose, looseY])
        NSLayoutConstraint.activate(sizeConstraints)

        // The window holds the larger card wherever the slide carries it.
        let travel = max(Self.travel, abs(offset.dx), abs(offset.dy))
        host.travelMargin = travel
        let margin = PopupStyle.standard.shadowMargin + travel
        restCardFrame = rest
        setFrame(bigFrame.insetBy(dx: -margin, dy: -margin), display: false)
        host.layoutSubtreeIfNeeded()

        Self.morphGeneration += 1
        let generation = Self.morphGeneration
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.cornerRadius = host.cornerRadius
        mask.cornerCurve = .continuous
        mask.anchorPoint = corner
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.bounds = CGRect(origin: .zero, size: rest.size)
        mask.position = CGPoint(x: corner.x * big.width, y: corner.y * big.height)
        glassLayer.mask = mask
        CATransaction.commit()
        activeMorph = HoverCardMorph(mask: mask, corner: corner, generation: generation)

        let shownFrom = CGRect(origin: .zero, size: previous.size)
        CATransaction.begin()
        CATransaction.setMainCompletion { [weak self] in self?.finishMorph(generation) }
        Motion.hoverCards.set(mask, "bounds", to: NSValue(rect: CGRect(origin: .zero, size: rest.size)), spring: .panel, from: NSValue(rect: shownFrom))
        // The shadow and its cutout follow the visible card (host coordinates, before the slide).
        let cardInHost = glass.frame
        func rounded(_ size: CGSize) -> CGPath {
            let rect = CGRect(x: cardInHost.minX + corner.x * (cardInHost.width - size.width),
                              y: cardInHost.minY + corner.y * (cardInHost.height - size.height), width: size.width, height: size.height)
            let radius = host.cornerRadius
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        func cutout(_ size: CGSize) -> CGPath {
            let path = CGMutablePath()
            path.addRect(host.bounds)
            path.addPath(rounded(size))
            return path
        }
        Motion.hoverCards.set(host.shadowLayer, "shadowPath", to: rounded(rest.size), spring: .panel, from: rounded(previous.size))
        if let cutoutLayer = host.shadowLayer.mask as? CAShapeLayer {
            Motion.hoverCards.set(cutoutLayer, "path", to: cutout(rest.size), spring: .panel, from: cutout(previous.size))
        }
        slide(from: offset)
        CATransaction.commit()
        return true
    }

    /// Ends the morph in flight (or only `generation`'s): the card is laid out at rest at once,
    /// where the morph was going.
    func finishMorph(_ generation: Int? = nil) {
        guard let activeMorph, generation == nil || generation == activeMorph.generation else { return }
        self.activeMorph = nil
        glass.layer?.mask = nil
        // The shadow's springs ran in the larger layout's coordinates: the rest layout redraws it.
        host?.shadowLayer.removeAnimation(forKey: "shadowPath")
        host?.shadowLayer.mask?.removeAnimation(forKey: "path")
        NSLayoutConstraint.deactivate(sizeConstraints)
        NSLayoutConstraint.activate(edgeConstraints)
        host?.travelMargin = Self.travel
        let margin = Self.windowMargin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrame(restCardFrame.insetBy(dx: -margin, dy: -margin), display: true)
        host?.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }
}
