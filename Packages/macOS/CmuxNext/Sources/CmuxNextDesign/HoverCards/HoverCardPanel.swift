public import AppKit

/// Where a card sits relative to its target.
public enum HoverCardPlacement: Sendable {
    /// Under the target, left-aligned (tab strips).
    case below
    /// Over the target, left-aligned (a tab strip at the bottom, R109).
    case above
    /// Right of the target, top-aligned (sidebar rows).
    case beside
}

/// The one hover card window of the app: a borderless, non-activating,
/// click-through child window holding a glass card (opaque under Reduce
/// Transparency, `OverlaySurfaceView`) in the popup style (`PopupStyle`). The coordinator owns
/// the only instance and swaps the card's body (a tab card or a workspace
/// card view, each reused) into it.
///
/// Motion (Lawrence 2026-10-18: "the card needs proper fade in and translation animation (when
/// hover to different consecutive cards)"): a first show fades in while the card moves the last
/// `entryOffset` points away from its target; a retarget (the next row or tab while a card
/// shows) puts the window at the new place at once, as R131 asked (a window-frame slide trailed
/// the pointer), and slides the card itself there inside the window (a layer translation on the
/// `.panel` spring, retargetable, so no layout runs per frame) while its content crossfades; a
/// hide fades out. Reduce Motion keeps only the fades.
@MainActor
final class HoverCardPanel: NSPanel {
    /// Live instances (the debug single-card check counts them).
    nonisolated(unsafe) static var liveInstances = 0

    /// The card's material; its `contentView` holds the body.
    let glass: OverlaySurfaceView
    /// The window's content: the card and its shadow, which the slide translates.
    private var host: PopupHostView? { contentView as? PopupHostView }
    /// How far a slide carries the card inside its window: the clear room kept around the
    /// shadow band. A retarget farther away jumps the rest at once (the card never trails).
    static let travel: CGFloat = 48
    /// How far a first show moves the card, away from its target, while it fades in.
    static let entryOffset: CGFloat = 6
    /// The window's clear band around the card: the shadow band plus the slide's room.
    private static var windowMargin: CGFloat { PopupStyle.standard.shadowMargin + travel }
    private weak var body: NSView?
    /// The shown card's text, one entry per line (`debug.hover_cards`); empty for a body that
    /// does not report it.
    var bodyLines: [String] { (body as? any HoverCardTextReporting)?.reportedLines ?? [] }
    private weak var parentWindowRef: NSWindow?
    private var anchor: CGRect = .zero
    private var placement: HoverCardPlacement = .below
    private var applyTheme: (() -> Void)?
    /// The scope the card draws in; a retarget within it adopts nothing again.
    private weak var adoptedScope: ThemeScope?

    init() {
        glass = Glass.makeOverlayPanel(cornerRadius: PopupStyle.standard.cornerRadius)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        Self.liveInstances += 1
        adoptPopupStyle(card: glass).travelMargin = Self.travel
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        // A no-activate test run is never active; its cards must still show.
        hidesOnDeactivate = !WindowPlacement.noActivate
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            Self.liveInstances -= 1
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The card's frame on screen at rest: the window less its clear band.
    var cardFrame: CGRect { frame.insetBy(dx: Self.windowMargin, dy: Self.windowMargin) }

    /// Where the card is drawn now: its rest frame moved by the slide in flight.
    private var presentedCardFrame: CGRect {
        let transform = slideLayer.flatMap { (Motion.presentationValue($0, "sublayerTransform") as? NSValue)?.caTransform3DValue }
            ?? CATransform3DIdentity
        return cardFrame.offsetBy(dx: transform.m41, dy: transform.m42)
    }

    /// The layer whose sublayer translation slides the card (and its shadow) inside the window.
    private var slideLayer: CALayer? { host?.layer }

    /// The card is on screen (fading in or shown), not fading out.
    var isShowingCard: Bool { isVisible && parentWindowRef != nil && !isDismissing }
    private var isDismissing = false

    /// Shows `body` at `anchor` (screen) as a child of `parent`. `themeAnchor`
    /// is the view the card describes; the card draws in its theme scope.
    /// `sliding` (a retarget of a visible card) moves it in the same frame
    /// like any other placement; every show is at full strength on the first frame.
    func present(body newBody: NSView, anchor: CGRect, placement: HoverCardPlacement, parent: NSWindow,
                 themeAnchor: NSView?, sliding: Bool, applyTheme: @escaping () -> Void) {
        let wasDismissing = isDismissing
        let wasOnScreen = isVisible && parentWindowRef === parent
        // Where the card is on screen before this show: a visible card (shown, or fading out
        // and shown again in one turn) slides from there; a hidden one enters fresh.
        let previous = wasOnScreen ? presentedCardFrame : nil
        isDismissing = false
        if previous != nil, sliding || wasDismissing { crossfadeContent() }
        if body !== newBody {
            body?.removeFromSuperview()
            newBody.translatesAutoresizingMaskIntoConstraints = false
            let container = glass.contentView
            container.addSubview(newBody)
            NSLayoutConstraint.activate([
                newBody.topAnchor.constraint(equalTo: container.topAnchor),
                newBody.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                newBody.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                newBody.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            body = newBody
        }
        // The card draws in the theme scope of the view it describes and
        // follows that scope's changes while it shows, at full strength even
        // over an unfocused pane's subtle strip.
        let scope = (themeAnchor?.themeScope ?? parent.themeScope).fullStrength
        self.applyTheme = applyTheme
        if adoptedScope !== scope {
            scope.adopt(self)
            scope.addResponder(self)
            adoptedScope = scope
            themeDidChange()
        } else {
            applyTheme()
        }
        if parentWindowRef !== parent {
            parentWindowRef?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
            parentWindowRef = parent
        }
        self.anchor = anchor
        self.placement = placement
        place()
        if let previous {
            // A visible card: it slides from where it is drawn to its new place (a quick return
            // during the fade-out fades back in from the alpha it reached).
            slide(from: offset(of: previous, to: cardFrame))
            if wasDismissing || alphaValue < 1 { Motion.animateTimed(.fadeIn, in: contentView) { animator().alphaValue = 1 } }
        } else {
            // A first show: from clear, the card fades in while it moves the last few points
            // away from its target.
            Motion.withoutAnimation { animator().alphaValue = 0 }
            orderFront(nil)
            slide(from: Self.entryVector(for: placement))
            Motion.animateTimed(.fadeIn, in: contentView) { animator().alphaValue = 1 }
        }
    }

    /// Slides the card from `offset` (points from its rest place) back to rest on the panel
    /// spring, starting from what is on screen. Reduce Motion or speed off: at rest at once.
    private func slide(from offset: CGVector) {
        guard let slideLayer else { return }
        let start = CATransform3DMakeTranslation(offset.dx, offset.dy, 0)
        Motion.set(slideLayer, "sublayerTransform", to: NSValue(caTransform3D: CATransform3DIdentity), spring: .panel,
                   from: NSValue(caTransform3D: start))
    }

    /// The translation that draws a card at rest at `to` where `from` is now: aligned on the
    /// edge the placement keeps fixed (the top beside or below a target, the bottom above
    /// one), at most `travel` each way.
    private func offset(of from: CGRect, to: CGRect) -> CGVector {
        let dy = placement == .above ? from.minY - to.minY : from.maxY - to.maxY
        let travel = Self.travel
        return CGVector(dx: min(max(from.minX - to.minX, -travel), travel), dy: min(max(dy, -travel), travel))
    }

    /// Where a first show starts, from its rest place: toward the target it describes.
    static func entryVector(for placement: HoverCardPlacement) -> CGVector {
        switch placement {
        case .below: CGVector(dx: 0, dy: entryOffset)
        case .above: CGVector(dx: 0, dy: -entryOffset)
        case .beside: CGVector(dx: -entryOffset, dy: 0)
        }
    }

    /// The card's next content fades over its last frame (the body is reused, so its text,
    /// thumbnail and size change in place this turn). Only the content crossfades: the glass,
    /// its edge and its shadow stay one card that slides. Off at speed off; short under Reduce
    /// Motion.
    private func crossfadeContent() {
        let duration = Motion.duration(.crossfade)
        let content = glass.contentView
        content.wantsLayer = true
        guard duration > 0, Motion.canAnimate(in: glass), let layer = content.layer else { return }
        // motion-allow: a crossfade transition on Motion's .crossfade duration, gated by Motion.canAnimate
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        // motion-allow: the crossfade's ease-out curve (CATransition takes no Motion curve)
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "hoverCard.crossfade")
    }

    /// Recolors the glass and the body in the card's theme scope.
    func themeDidChange() {
        glass.applyTheme()
        applyTheme?()
    }

    /// The target moved: the card follows it at once.
    func follow(_ newAnchor: CGRect) {
        guard newAnchor != anchor, isShowingCard else { return }
        anchor = newAnchor
        place()
    }

    /// The body's size changed (a resources row appeared).
    func refit() {
        guard isShowingCard else { return }
        place()
    }

    private func place() {
        glass.layoutSubtreeIfNeeded()
        let scale = max(parentWindowRef?.backingScaleFactor ?? 2, 1)
        // Whole device pixels, so the edge `origin(for:)` puts on the target stays there.
        let fitting = glass.fittingSize
        let size = CGSize(width: (fitting.width * scale).rounded(.up) / scale, height: (fitting.height * scale).rounded(.up) / scale)
        var origin = Self.origin(for: placement, anchor: anchor, size: size, scale: scale)
        if let screen = parentWindowRef?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let margin = Metrics.space2
            origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
            origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        }
        // R131: the window moves in the same frame (a window-frame slide restarted on every tab
        // trailed the pointer); a retarget's slide runs inside it (`slide(from:)`).
        let margin = Self.windowMargin
        setFrame(CGRect(origin: origin, size: size).insetBy(dx: -margin, dy: -margin), display: true)
    }

    func dismiss() {
        guard isVisible, !isDismissing else { return }
        isDismissing = true
        Motion.animateTimed(.fadeOut, in: contentView, { animator().alphaValue = 0 }, completion: { [weak self] in
            guard let self, self.isDismissing else { return }
            self.isDismissing = false
            self.parentWindowRef?.removeChildWindow(self)
            self.parentWindowRef = nil
            self.orderOut(nil)
        })
    }
}

extension HoverCardPanel: ThemeResponsive {}

extension HoverCardPanel {
    /// The room between a card and its target: none. The card touches its tab (or row), so the
    /// pointer never crosses empty space between them (Lawrence 2026-10-19: "there is a gap in
    /// between ... such that there is no gap in between").
    static let targetGap: CGFloat = 0

    /// The card's origin (screen coordinates, y up) for `placement` next to `anchor`, before
    /// the screen clamp. The touching edge is snapped to a device pixel of `scale` toward the
    /// target, so a fractional anchor overlaps it by under a pixel and never leaves a seam.
    static func origin(for placement: HoverCardPlacement, anchor: CGRect, size: CGSize, scale: CGFloat = 2) -> CGPoint {
        let scale = max(scale, 1)
        func up(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.up) / scale }
        func down(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.down) / scale }
        return switch placement {
        // The card's top edge on the tab's bottom edge (rounded up: into the tab, never below it).
        case .below: CGPoint(x: anchor.minX, y: up(anchor.minY - targetGap) - size.height)
        // The card's bottom edge on the tab's top edge (rounded down: into the tab).
        case .above: CGPoint(x: anchor.minX, y: down(anchor.maxY + targetGap))
        // The card's leading edge on the row's trailing edge, top-aligned.
        case .beside: CGPoint(x: down(anchor.maxX + targetGap), y: anchor.maxY - size.height)
        }
    }
}
