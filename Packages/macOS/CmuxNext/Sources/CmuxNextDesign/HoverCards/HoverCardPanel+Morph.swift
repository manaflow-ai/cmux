import AppKit
import CmuxNextCompat
import CmuxNextDesignTokens
import CmuxNextWakeups

/// A body whose layout can stay as it was while the card folds to a smaller size: the workspace
/// card's Hide details keeps its detail rows drawn (fading out) under the folding edge, instead of
/// dropping them at once and folding an empty card after them.
@MainActor
public protocol HoverCardFoldingBody: AnyObject {
    /// The card folds now from the size this body had: keep that layout until ``endFoldHold()``.
    /// Returns false when nothing is held (the body lays out at its new size at once).
    func holdLayoutWhileFolding() -> Bool
    /// The fold ended (settled, or replaced): the body takes its new layout.
    func endFoldHold()
}

/// A resize in flight: the card's surface (the glass, its rim and its shadow) at the size the spring
/// is at now, about the corner that stays on the target, inside a window that holds the larger of the
/// two sizes. It steps on the panel window's ``MotionClock`` and sets the real frame each frame, so the
/// rim, the corners and the shadow are drawn at the card's size on every frame (a mask over a card laid
/// out at the larger size cut the rim and the rounded corners off the moving edge, and the shadow ran
/// on separate springs that the rest layout redrew at the end: msg 38370's recording).
@MainActor
final class HoverCardMorph: MotionAnimating {
    /// The corner of the card that stays on the target while the size changes (unit coordinates, y up).
    let corner: CGPoint
    /// Bumped per morph, so a finished morph's completion leaves a newer one alone.
    let generation: Int
    /// The size the card is drawn at when the morph starts, and the size it goes to.
    let from: CGSize
    let to: CGSize
    /// The body keeps its last layout while the card folds (``HoverCardFoldingBody``).
    let holdsLayout: Bool
    private let spring: MotionSpring
    private var width: SpringValue
    private var height: SpringValue
    private weak var panel: HoverCardPanel?
    /// The size reached and shown, finish on the next frame (the last frame is on screen first).
    private var landed = false
    /// Inside this morph's own `motionStep` (its finish must not stop it on the clock mid-step).
    private(set) var isStepping = false

    init(panel: HoverCardPanel, corner: CGPoint, generation: Int, from: CGSize, to: CGSize, spring: MotionSpring, holdsLayout: Bool) {
        self.panel = panel
        self.corner = corner
        self.generation = generation
        self.from = from
        self.to = to
        self.spring = spring
        self.holdsLayout = holdsLayout
        width = SpringValue(to.width)
        width.value = from.width
        height = SpringValue(to.height)
        height.value = from.height
    }

    /// The size shown now.
    var size: CGSize { CGSize(width: width.value, height: height.value) }

    func motionStep(_ dt: Double) -> Bool {
        isStepping = true
        defer { isStepping = false }
        guard let panel, panel.activeMorph === self else { return false }
        if landed {
            panel.finishMorph(generation)
            return false
        }
        let parameters = Motion.hoverCards.spring(spring)
        let wide = width.advance(dt, parameters: parameters, epsilon: 0.1)
        let tall = height.advance(dt, parameters: parameters, epsilon: 0.1)
        panel.applyMorphFrame()
        if !wide, !tall { landed = true }
        return true
    }

    func motionSettle() {
        width.snap()
        height.snap()
        guard let panel, panel.activeMorph === self else { return }
        panel.finishMorph(generation)
    }
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
// How: the window holds the larger of the two sizes; the body stays pinned to the fixed corner at its
// own size (or, folding, at the size it had: `HoverCardFoldingBody`), clipped by the card's content
// view; and the card's real frame, rim and shadow take the spring's size on each frame of the window's
// clock (`HoverCardMorph`). When the spring settles the card is laid out at rest again.
extension HoverCardPanel {
    private(set) static var morphGeneration = 0

    /// The card's rest frame at the size a morph in flight shows now.
    var presentedSize: CGRect {
        guard let activeMorph else { return cardFrame }
        let shown = activeMorph.size
        let rest = restCardFrame
        let x = activeMorph.corner.x == 0 ? rest.minX : rest.maxX - shown.width
        let y = activeMorph.corner.y == 0 ? rest.minY : rest.maxY - shown.height
        return CGRect(x: x, y: y, width: shown.width, height: shown.height)
    }

    /// The corner of the card that stays on its target while it resizes (unit, y up).
    var fixedCorner: CGPoint {
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
    /// match (unless `always`: a tab card's glide, which needs the window to hold the whole way),
    /// or when motion is off; the caller then slides or places it at once. `folds`: the same body
    /// changed size in place (a refit), so a smaller card may keep its last layout while it folds.
    @discardableResult
    func morph(from previous: CGRect, spring: MotionSpring = .panel, always: Bool = false, folds: Bool = false) -> Bool {
        // Where `place()` put the card (the window may still be at the last card's: a glide sets it here).
        let rest = restCardFrame
        guard always || abs(previous.width - rest.width) > 0.5 || abs(previous.height - rest.height) > 0.5 else { return false }
        // The same gate as the slide it runs with (`Motion.set`): Reduce Motion, speed off, or a live resize of the
        // window this card is a child of, resize at once.
        guard Motion.hoverCards.animatesMovement(in: self), let host, let body else { return false }
        let corner = fixedCorner
        // The larger card the window holds, about the fixed corner.
        let big = CGSize(width: max(previous.width, rest.width), height: max(previous.height, rest.height))
        let bigFrame = CGRect(x: corner.x == 0 ? rest.minX : rest.maxX - big.width,
                              y: corner.y == 0 ? rest.minY : rest.maxY - big.height, width: big.width, height: big.height)
        // Where the fixed corner was, from where it goes: the translation the card slides from.
        let from = CGPoint(x: corner.x == 0 ? previous.minX : previous.maxX, y: corner.y == 0 ? previous.minY : previous.maxY)
        let to = CGPoint(x: corner.x == 0 ? rest.minX : rest.maxX, y: corner.y == 0 ? rest.minY : rest.maxY)
        let offset = CGVector(dx: from.x - to.x, dy: from.y - to.y)

        // A fold of the same content (Hide details): the body keeps the layout it had, drawn under the folding
        // edge, and takes its new one when the fold ends. Otherwise it is at its own new size from the start.
        let grows = previous.width < rest.width - 0.5 || previous.height < rest.height - 0.5
        let shrinks = !grows && (previous.width > rest.width + 0.5 || previous.height > rest.height + 0.5)
        let holds = folds && shrinks && leavingBody == nil && (body as? HoverCardFoldingBody)?.holdLayoutWhileFolding() == true
        let bodySize = holds ? previous.size : rest.size

        // The body keeps its size, pinned to the fixed corner, while the card is another size.
        sizeConstraints[0].constant = bodySize.width
        sizeConstraints[1].constant = bodySize.height
        let loose = corner.x == 0 ? edgeConstraints[3] : edgeConstraints[2]
        let looseY = corner.y == 0 ? edgeConstraints[0] : edgeConstraints[1]
        NSLayoutConstraint.deactivate([loose, looseY])
        NSLayoutConstraint.activate(sizeConstraints)

        // The window holds the larger card wherever the slide carries it.
        let travel = max(Self.travel, abs(offset.dx), abs(offset.dy))
        let margin = PopupStyle.standard.shadowMargin + travel
        restCardFrame = rest
        Self.morphGeneration += 1
        let morph = HoverCardMorph(panel: self, corner: corner, generation: Self.morphGeneration, from: previous.size, to: rest.size,
                                   spring: spring, holdsLayout: holds)
        activeMorph = morph
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The card's first frame, in the host the window is about to be, before the window takes that frame: its one
        // layout is then at the size it shows (not first at the whole larger card, then again at the morph's size).
        host.cardRect = morphCardRect(in: CGRect(x: margin, y: margin, width: big.width, height: big.height))
        host.travelMargin = travel
        setFrame(bigFrame.insetBy(dx: -margin, dy: -margin), display: false)
        applyMorphFrame()
        CATransaction.commit()
        slide(from: offset)
        MotionClock.forWindow(self).run(morph, trace: "hoverCard.morph")
        return true
    }

    /// The card's surface, rim and shadow at the size the morph in flight is at now (whole device
    /// pixels, so its edge stays crisp), about the fixed corner of the larger card the window holds.
    func applyMorphFrame() {
        guard activeMorph != nil, let host else { return }
        host.cardRect = morphCardRect(in: host.restingCardRect)
        // The body moves with the corner it is pinned to in this same commit (its size does not change).
        host.layoutSubtreeIfNeeded()
    }

    /// The card's frame at the morph's size now, about its fixed corner of `full` (the larger card's rect in the host).
    private func morphCardRect(in full: CGRect) -> CGRect? {
        guard let activeMorph else { return nil }
        let scale = max(backingScaleFactor, 1)
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let size = CGSize(width: min(pixel(activeMorph.size.width), full.width), height: min(pixel(activeMorph.size.height), full.height))
        let corner = activeMorph.corner
        return CGRect(x: full.minX + corner.x * (full.width - size.width), y: full.minY + corner.y * (full.height - size.height),
                      width: size.width, height: size.height)
    }

    /// A first show that grows out of its target (`HoverCardEntrance.morph`): the same resize as a
    /// retarget's, from a drop as wide as the target (at most the card) and as tall as the card's
    /// rounded corners, on the card's touching edge, to the whole card, on the settle spring. The
    /// card stops on its rest size: it does not stretch past it and pull back (that stretch, Leo
    /// 2026-11-07, went with every other bounce, Lawrence 2026-11-10). Motion off: no growth, the
    /// fade alone.
    @discardableResult
    func grow() -> Bool {
        let rest = cardFrame
        guard rest.width > 0.5, rest.height > 0.5 else { return false }
        let width = min(max(anchorFrame.width, 1), rest.width)
        let height = min(rest.height, 2 * (host?.cornerRadius ?? Self.cornerRadius))
        let seed = CGRect(x: isLeading ? rest.maxX - width : rest.minX,
                          y: restingPlacement == .above ? rest.minY : rest.maxY - height, width: width, height: height)
        return morph(from: seed, spring: .settle)
    }

    /// Ends the morph in flight (or only `generation`'s): the card is laid out at rest at once,
    /// where the morph was going. What waited for it (a refit, a glide's leaving content) runs now.
    func finishMorph(_ generation: Int? = nil) {
        guard let morph = activeMorph, generation == nil || generation == morph.generation else { return }
        activeMorph = nil
        if !morph.isStepping { MotionClock.forWindow(self).stop(morph) }
        if morph.holdsLayout { (body as? HoverCardFoldingBody)?.endFoldHold() }
        NSLayoutConstraint.deactivate(sizeConstraints)
        NSLayoutConstraint.activate(edgeConstraints)
        let margin = Self.windowMargin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host?.cardRect = nil
        host?.travelMargin = Self.travel
        setFrame(restCardFrame.insetBy(dx: -margin, dy: -margin), display: true)
        host?.layoutSubtreeIfNeeded()
        CATransaction.commit()
        // A settled morph (not one a newer show or a hide ended): what changed while it ran takes its place now.
        guard generation != nil else { return }
        endLeaving()
        if let animated = pendingRefit {
            pendingRefit = nil
            refit(animated: animated)
        }
        bodyRests()
    }

    /// The card rests at its size: once this frame committed, a body that reports its own size measures what its next
    /// change asks for (not while a morph runs: the morph's frames keep the main thread for themselves).
    func bodyRests() {
        guard body is HoverCardSizeReporting else { return }
        AfterFrameCommit().run { [weak self] in
            guard let self, self.activeMorph == nil, self.isShowingCard, let body = self.body as? HoverCardSizeReporting else { return }
            body.prepareSizes()
        }
    }
}
