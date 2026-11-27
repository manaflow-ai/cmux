public import AppKit
public import CmuxNextDesignTokens

/// Where a card sits relative to its target.
public enum HoverCardPlacement: Sendable {
    /// Under the target, left-aligned (tab strips).
    case below
    /// Over the target, left-aligned (a tab strip at the bottom, R109).
    case above
    /// Right of the target, top-aligned (the update card).
    case beside
    /// Beside a sidebar row, touching its anchor (a workspace's drawn fill, or a group/rail band),
    /// its top on the row's top as Chrome's
    /// and Arc's tab cards (or on the row's middle, below an escape slot, under a Debug switch:
    /// `HoverCardEscapeGeometry`).
    case besideRow
}

/// The one hover card window of the app: a borderless, non-activating,
/// click-through child window holding a glass card (opaque under Reduce
/// Transparency, `OverlaySurfaceView`) in the popup style (`PopupStyle`), shaped like the other
/// floating glass panels (`cornerRadius`). The coordinator owns
/// the only instance and swaps the card's body (a tab card or a workspace
/// card view, each reused) into it.
///
/// Motion (Lawrence 2026-10-18: "the card needs proper fade in and translation animation (when
/// hover to different consecutive cards)"): a sidebar row's first show is immediate after its
/// dwell (Leo 2026-10-28, ask-067e9aa217). Other cards fade in while the card moves the last
/// `entryOffset` points away from its target; a retarget (the next row or tab while a card
/// shows) puts the window at the new place at once, as R131 asked (a window-frame slide trailed
/// the pointer), and slides the card itself there inside the window (a layer translation on the
/// `.panel` spring, retargetable, so no layout runs per frame) while its content crossfades; a
/// hide fades out. Reduce Motion keeps only the fades.
///
/// One card, never two (Lawrence 2026-10-20: "only one card, one offer card, appears at any point
/// in time, at all times"): the sidebar's Update Ready highlights show in this same window
/// (`HoverCardCoordinator.presentOwned`), so going between them and a workspace card morphs the
/// one card. A retarget to a card of another size resizes the card on the same spring while it
/// translates (`HoverCardPanel+Morph.swift`), instead of popping to the new size.
@MainActor
final class HoverCardPanel: NSPanel, FullScreenFollowingChild {
    /// Live instances (the debug single-card check counts them).
    nonisolated(unsafe) static var liveInstances = 0

    /// The card's material; its `contentView` holds the body.
    let glass: OverlaySurfaceView
    /// The shared hover surface's look the glass draws (``HoverSurfaceLook``): set at init, and again on a
    /// show after the setting changed (a test or the material gallery may pin the material between).
    private var hoverLook: HoverSurfaceLook
    /// The window's content: the card and its shadow, which the slide translates.
    var host: PopupHostView? { contentView as? PopupHostView }
    /// How far a slide carries the card inside its window: the clear room kept around the
    /// shadow band. A retarget farther away jumps the rest at once (the card never trails).
    static let travel: CGFloat = 48
    /// How far a first show moves the card, away from its target, while it fades in.
    static var entryOffset: CGFloat { motion.entryOffset }
    /// The entrance and exit every hover card plays (the update card's too).
    static let motion = HoverCardMotion.standard
    /// The card's continuous radius: the floating glass panels' (the palette, dialogs), not a
    /// menu's 8 pt (Leo 2026-10-20: the hover card in iOS's glass style). The shadow follows it.
    static var cornerRadius: CGFloat { Metrics.panelCornerRadius }
    /// The window's clear band around the card: the shadow band plus the slide's room.
    static var windowMargin: CGFloat { PopupStyle.standard.shadowMargin + travel }
    weak var body: NSView?
    /// Hears the pointer in the window's clear band (``HoverCardPanel/pointerMovedInBand()``).
    let bandTracker = HoverCardBandTracker()
    /// The body's edges pinned to the card (the card fits its body), and its fitted size, held
    /// while a morph lays the card out larger (`HoverCardPanel+Morph.swift`).
    var edgeConstraints: [NSLayoutConstraint] = []
    var sizeConstraints: [NSLayoutConstraint] = []
    /// A resize in flight between two cards of different sizes.
    var activeMorph: HoverCardMorph?
    /// The last card's content fading out at its own size, pinned to the fixed corner, while the
    /// next card's fades in over it (a tab card's glide, `HoverCardPanel+Glide.swift`).
    var leavingBody: NSView?
    /// The last glide's content after its fade: hidden in the card, not taken out of the window, so the
    /// tab card's next swap (which shows it again, `TabHoverCardController`'s two views) lays out no
    /// view new to the window (msg 34360's cost check: 2 ms a show when it left the window).
    var parkedBody: NSView?
    /// How the last show moved (`debug.hover_cards` `last_present`): flags only, formatted when read.
    private(set) var lastPresent = HoverCardPresentNote()
    /// A refit asked for while a morph runs (nil: none; true: it animates): it runs when the morph
    /// ends, so a resources sample landing mid-glide never cuts the glide's window (msg 34360).
    var pendingRefit: Bool?
    /// The card takes clicks and scrolls (the update highlights' "See all changes").
    private(set) var isInteractive = false
    /// The current press began in the clear band around the card: it and its drags and release
    /// go to the parent window (`HoverCardPanel+ClickThrough.swift`).
    var forwardsPress = false
    /// A `.beside` card sits left of its target (no room on its right: a sidebar on the right).
    private(set) var isLeading = false
    /// The card's frame on screen at rest, while a morph lays the window out larger.
    var restCardFrame: CGRect = .zero
    /// The shown card's text, one entry per line (`debug.hover_cards`); empty for a body that
    /// does not report it.
    var bodyLines: [String] { (body as? any HoverCardTextReporting)?.reportedLines ?? [] }
    private weak var parentWindowRef: NSWindow?
    private var anchor: CGRect = .zero
    /// The target's frame on screen the card is placed against (`debug.hover_cards`).
    var anchorFrame: CGRect { anchor }
    private(set) var placement: HoverCardPlacement = .below
    /// The side the card rests on now: `placement`, or the other side when the screen has no room.
    private(set) var restingPlacement: HoverCardPlacement = .below
    private var applyTheme: (() -> Void)?
    /// A `.besideRow` card's geometry at rest: its row, its frame and its escape slot.
    private(set) var escapeGeometry: HoverCardEscapeGeometry?
    /// The scope the card draws in; a retarget within it adopts nothing again.
    private weak var adoptedScope: ThemeScope?
    /// The clock shows are timed on (Core Animation's media time); tests pass their own.
    var now: () -> CFTimeInterval = CACurrentMediaTime
    /// When the last show or retarget ran (`now`): the next one sooner than
    /// `HoverCardTiming.sweepInterval` is part of a sweep.
    private var lastPresentAt: CFTimeInterval?

    /// `deferred` false makes the window-server window now (``HoverCardCoordinator/warm()``), not on the first show.
    init(deferred: Bool = true) {
        // `PopupHostView` resets an overlay card to the popup radius; the host's radius below sets it back.
        // Bare themed glass, no solid card fill (`Glass.makeOverlayPanel`'s `cardFill`).
        glass = Glass.makeOverlayPanel(cornerRadius: Self.cornerRadius, tone: .neutralGlass(.transient))
        // The card is its clear window's whole content: before macOS 26 its blur samples what is
        // behind the window (the sidebar, a terminal), as its Liquid Glass refracts it.
        glass.samplesBehindWindow = true
        // The shared hover surface: solid by default, the glass above when the setting says so.
        hoverLook = HoverSurfaceLook.current
        hoverLook.apply(to: glass)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: deferred)
        Self.liveInstances += 1
        let host = adoptPopupStyle(card: glass)
        host.travelMargin = Self.travel
        host.cornerRadius = Self.cornerRadius
        bandTracker.panel = self
        host.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                            owner: bandTracker))
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

    /// The window stays where `place()` puts it: `rest(for:)` already keeps the card on screen.
    /// The window is the card plus its clear band (`windowMargin`), so a tab just under the menu
    /// bar puts the band's top in the menu bar, and AppKit's default constraint moved the whole
    /// window, card and all, down below it: the card hung a toolbar's height under its tab
    /// (Austin 2026-10-20: "The cards, when I hover on the tabs, are not connected to the tabs
    /// themselves"). The band is clear and click-through, so it may sit under the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// The card's frame on screen at rest: the window less its clear band.
    var cardFrame: CGRect { activeMorph == nil ? frame.insetBy(dx: Self.windowMargin, dy: Self.windowMargin) : restCardFrame }

    /// Where the card is drawn now: its rest frame (at the size a morph in flight shows) moved
    /// by the slide in flight.
    var presentedCardFrame: CGRect {
        let transform = slideLayer.flatMap { (Motion.presentationValue($0, "sublayerTransform") as? NSValue)?.caTransform3DValue }
            ?? CATransform3DIdentity
        return presentedSize.offsetBy(dx: transform.m41, dy: transform.m42)
    }

    /// The layer whose sublayer translation slides the card (and its shadow) inside the window.
    var slideLayer: CALayer? { host?.layer }

    /// The card is on screen (fading in or shown), not fading out.
    var isShowingCard: Bool { isVisible && parentWindowRef != nil && !isDismissing }
    private var isDismissing = false

    /// Shows `body` at `anchor` (screen) as a child of `parent`. `themeAnchor`
    /// is the view the card describes; the card draws in its theme scope.
    /// `sliding` retargets a visible card. A sidebar row's first show is at full strength
    /// and at rest in this frame; the coordinator has already waited for the dwell.
    func present(body newBody: NSView, anchor: CGRect, placement: HoverCardPlacement, parent: NSWindow,
                 themeAnchor: NSView?, sliding: Bool, interactive: Bool = false, cornerRadius: CGFloat? = nil,
                 entrance: HoverCardEntrance = .slide, retarget: HoverCardRetarget = .jump,
                 applyTheme: @escaping () -> Void) {
        if HoverSurfaceLook.current != hoverLook {
            hoverLook = HoverSurfaceLook.current
            hoverLook.apply(to: glass)
        }
        let wasDismissing = isDismissing
        let wasOnScreen = isVisible && parentWindowRef === parent
        // Where the card is on screen before this show: a visible card (shown, or fading out
        // and shown again in one turn) slides from there; a hidden one enters fresh.
        let previous = wasOnScreen ? presentedCardFrame : nil
        // A sweep (the pointer crosses rows faster than the slide settles): the card is at its
        // row with its new content in this frame. Restarting the slide and the crossfade on
        // every row made it trail the pointer with doubled text (msg 15501).
        let time = now()
        // A card that hangs from its target (a tab's, a chip's) switches in place by default: under the
        // next target with its content in this frame, never a slide from the last one (Leo 2026-11-18:
        // "the hover preview bounces for some reason"). `.glide` keeps the glide (`glidesWholeWay`).
        let hangs = previous != nil && Self.glidesWholeWay(placement)
        let inPlace = hangs && retarget != .glide
        let glides = hangs && retarget == .glide
        let sweeping = inPlace || (previous != nil && !wasDismissing && !glides
            && lastPresentAt.map { time - $0 < HoverCardTiming.sweepInterval.hoverCardSeconds } == true)
        // The last card's content fades out at its own size while the next one's fades in, instead of a
        // snapshot of the card stretched over the next card's size (msg 34360).
        let fadesBodies = glides && body != nil && body !== newBody && Motion.hoverCards.animatesMovement(in: self)
        lastPresentAt = time
        let sameBody = body === newBody
        pendingRefit = nil
        isDismissing = false
        dismissCompletion = nil
        // A morph still running lays its card out at rest first: the next one starts from what
        // is drawn now (`previous`, read above).
        finishMorph()
        if sweeping {
            glass.contentView.layer?.removeAnimation(forKey: Self.crossfadeKey)
            // `.crossfade`: the card is at the next target at once; only its content fades over the last.
            if inPlace, retarget == .crossfade, body !== newBody { crossfadeContent() }
        } else if previous != nil, !fadesBodies, sliding || body !== newBody {
            // A return to the card fading out (not sliding, the same body) keeps its content as drawn: a
            // crossfade of a card over itself flickered its spinners (Leo 2026-11-02, "IT RE-RENDERS THE
            // SPINNER VIEW"). Another target's content (`sliding`) still fades over the last.
            crossfadeContent()
        }
        install(newBody, fades: fadesBodies)
        isInteractive = interactive
        ignoresMouseEvents = !interactive
        acceptsMouseMovedEvents = interactive
        // The card draws in the theme scope of the view it describes and
        // follows that scope's changes while it shows, at full strength even
        // over an unfocused pane's subtle strip.
        adoptTheme(of: themeAnchor, parent: parent, applyTheme: applyTheme)
        if parentWindowRef !== parent {
            parentWindowRef?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
            parentWindowRef = parent
        }
        self.anchor = anchor
        self.placement = placement
        // This card's shape (a tab's card has the tab's), read on every show: the density setting
        // may have changed the radius since the last card.
        host?.cornerRadius = cornerRadius ?? Self.cornerRadius
        // A glide sets the window's frame once, to the frame that holds both places (`morph`): placed at
        // rest first, the window was resized and drawn twice in one show (msg 34360: 3 ms a show).
        let morphs = glides && !sweeping && Motion.hoverCards.animatesMovement(in: self)
        MotionTrace.measure("hoverCard.place") { place(appliesFrame: !morphs) }
        lastPresent = HoverCardPresentNote(onScreen: previous != nil, glides: glides, sweeping: sweeping, fadesBodies: fadesBodies,
                                           sameBody: sameBody, moves: Motion.hoverCards.animatesMovement(in: self),
                                           liveResize: Motion.isLiveResizing(self), inPlace: inPlace)
        if sweeping {
            snapToRest()
            // The next tab reached while the last tab's card fades out: it fades back in from the alpha it
            // reached, at the next tab, with no second entrance.
            if inPlace, wasDismissing || alphaValue < 1 { Self.motion.resume(self) }
        } else if let previous {
            // A visible card: it slides from where it is drawn to its new place, and resizes
            // there when the next card is another size (a quick return during the fade-out
            // fades back in from the alpha it reached).
            lastPresent.morphed = MotionTrace.measure("hoverCard.morph") { morph(from: previous, always: glides) }
            if !lastPresent.morphed {
                if morphs { applyRestFrame() }
                slide(from: offset(of: previous, to: cardFrame))
            }
            if wasDismissing || alphaValue < 1 { Self.motion.resume(self) }
        } else if placement == .besideRow {
            // Leo: "We can just have it instantly come in on the first load; the delay
            // that we have is fine, maybe." Clear any slide left from the previous card.
            Motion.hoverCards.transaction(nil) {
                slideLayer?.removeAnimation(forKey: "sublayerTransform")
                slideLayer?.sublayerTransform = CATransform3DIdentity
            }
            Motion.hoverCards.withoutAnimation { animator().alphaValue = 1 }
            orderFront(nil)
        } else {
            // A first show: from clear, the card fades in while it moves the last few points
            // away from its target (`HoverCardMotion`, shared with the update card), fades in
            // where it rests, or grows out of its target (`grow()`; a plain fade when motion is off).
            Self.motion.enter(self, placement: restingPlacement, leading: isLeading, slides: entrance == .slide)
            if entrance == .morph { grow() }
        }
    }

    /// Puts `newBody` in the card in place of the last body: the last fades out at its own size while
    /// `newBody` fades in when `fades`, else the swap is at once (``warm(_:parent:)``); its last window gives it up first.
    private func install(_ newBody: NSView, fades: Bool = false) {
        guard body !== newBody else { return }
        MotionTrace.measure("hoverCard.swap") {
            if let holder = newBody.window as? HoverCardPanel, holder !== self { holder.giveUp(newBody) }
            if newBody === leavingBody { endLeaving() }
            if fades, let body { leave(body) } else { body?.removeFromSuperview() }
            let container = glass.contentView
            if newBody === parkedBody {
                parkedBody = nil
                newBody.isHidden = false
            }
            newBody.translatesAutoresizingMaskIntoConstraints = false
            if newBody.superview !== container { container.addSubview(newBody) }
            // Bottom and trailing just below required: `place()` lays the glass out at the last
            // card's size before it measures and resizes, and a required pair there conflicted
            // with the new body's fixed rows and width limits on every hover retarget (about 650
            // of 1564 "Unable to simultaneously satisfy constraints" in 3 h of NIGHTLY logs, up
            // to 39 a second, each solved and logged on the main thread). 999 still beats the
            // fitting-size compression, so `fittingSize` and the resting layout are the same.
            let bottom = newBody.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            bottom.priority = .init(999)
            let trailing = newBody.trailingAnchor.constraint(equalTo: container.trailingAnchor)
            trailing.priority = .init(999)
            edgeConstraints = [
                newBody.topAnchor.constraint(equalTo: container.topAnchor),
                bottom,
                newBody.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                trailing,
            ]
            sizeConstraints = [newBody.widthAnchor.constraint(equalToConstant: 0), newBody.heightAnchor.constraint(equalToConstant: 0)]
            NSLayoutConstraint.activate(edgeConstraints)
            body = newBody
            // A view that left a glide stays clear (`endLeaving`); it shows whole unless it fades in.
            if fades { fadeIn(newBody) } else if let layer = newBody.layer { Motion.setModel(layer, "opacity", Float(1)) }
        }
    }

    /// The card draws in the theme scope of `themeAnchor` (else `parent`'s), at full strength, and follows its changes.
    private func adoptTheme(of themeAnchor: NSView?, parent: NSWindow, applyTheme: @escaping () -> Void) {
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
    }

    /// Does a first show's one-time work with nothing on screen (``HoverCardCoordinator/warm()``): puts `card`'s
    /// body in the card, adopts its theme, lays the card out at its size and draws it once off screen (text layout,
    /// glyph and image caches). The first `present` of that body then only configures, places and orders it in.
    func warm(_ card: HoverCardBody, parent: NSWindow) {
        guard !isVisible else { return }
        install(card.view)
        adoptTheme(of: card.themeAnchor, parent: parent, applyTheme: card.applyTheme)
        host?.cornerRadius = card.cornerRadius ?? Self.cornerRadius
        glass.layoutSubtreeIfNeeded()
        let size = glass.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        setFrame(CGRect(origin: frame.origin, size: size).insetBy(dx: -Self.windowMargin, dy: -Self.windowMargin), display: false)
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
        }
    }

    /// Slides the card from `offset` (points from its rest place) back to rest on the panel
    /// spring, starting from what is on screen. Reduce Motion or speed off: at rest at once.
    func slide(from offset: CGVector) {
        guard let slideLayer else { return }
        let start = CATransform3DMakeTranslation(offset.dx, offset.dy, 0)
        Motion.hoverCards.set(slideLayer, "sublayerTransform", to: NSValue(caTransform3D: CATransform3DIdentity), spring: .panel,
                   from: NSValue(caTransform3D: start))
    }

    /// Puts the card at its rest place at once: a slide or an entrance translation in flight ends
    /// where it was going (a fade in flight runs on).
    func snapToRest() {
        guard let slideLayer else { return }
        slideLayer.removeAnimation(forKey: "sublayerTransform")
        Motion.setModel(slideLayer, "sublayerTransform", NSValue(caTransform3D: CATransform3DIdentity))
    }

    /// The translation that draws a card at rest at `to` where `from` is now: aligned on the
    /// edge the placement keeps fixed (the top beside or below a target, the bottom above
    /// one), at most `travel` each way.
    private func offset(of from: CGRect, to: CGRect) -> CGVector {
        let dy = restingPlacement == .above ? from.minY - to.minY : from.maxY - to.maxY
        let travel = Self.travel
        return CGVector(dx: min(max(from.minX - to.minX, -travel), travel), dy: min(max(dy, -travel), travel))
    }

    /// Where a first show starts, from its rest place: toward the target it describes.
    static func entryVector(for placement: HoverCardPlacement) -> CGVector {
        motion.entryVector(for: placement)
    }

    /// The key the content crossfade runs under: `kCATransition`, where Core Animation files every
    /// transition whatever key it is added with. Under its own key ("hoverCard.crossfade") a sweep's
    /// `removeAnimation(forKey:)` found nothing and the last move's crossfade ran on under the next card.
    static let crossfadeKey = kCATransition

    /// The card's next content fades over its last frame (the body is reused, so its text,
    /// thumbnail and size change in place this turn). Only the content crossfades: the glass,
    /// its edge and its shadow stay one card that slides. Off at speed off; short under Reduce
    /// Motion.
    func crossfadeContent() {
        let duration = Motion.hoverCards.duration(.crossfade)
        let content = glass.contentView
        content.wantsLayer = true
        guard duration > 0, Motion.canAnimate(in: glass), let layer = content.layer else { return }
        // motion-allow: a crossfade transition on Motion's .crossfade duration, gated by Motion.canAnimate
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        // motion-allow: the crossfade's ease-out curve (CATransition takes no Motion curve)
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: Self.crossfadeKey)
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
        finishMorph()
        place()
    }

    /// The body's size changed (a resources row appeared).
    func refit(animated: Bool = false) {
        guard isShowingCard else { return }
        // A morph in flight (a glide or a growth) lays the card out at rest when it ends: the refit
        // runs then, from the size it reached. Ended now, its window lost the room the card glides in.
        if activeMorph != nil {
            pendingRefit = (pendingRefit ?? false) || animated
            return
        }
        // What is drawn now, read before a morph in flight lays its card out at rest (as `present` does).
        let previous = animated ? presentedCardFrame : nil
        finishMorph()
        // An animated refit leaves the window where it is: the morph sets the one frame its first frame shows. A
        // window set to the rest frame first laid the card and its glass out at a size never shown, then the morph
        // set it back (the press of Show or Hide details was a late frame, Lawrence 2026-11-18).
        place(appliesFrame: previous == nil)
        // The same morph a retarget to another size runs: the card grows or folds about the fixed corner.
        if let previous, !morph(from: previous, folds: true) { applyRestFrame() }
    }

    /// Lays the card out for its anchor and size. `appliesFrame` false: the rest frame is worked out
    /// (`restCardFrame`) and the window stays where it is, for a morph that sets it next.
    func place(appliesFrame: Bool = true) {
        // A morph lays the card out once, at the size its first frame shows (`morph`): a layout here would be at the
        // size the window has now, never shown. The measure updates the content's constraints itself.
        if appliesFrame { glass.layoutSubtreeIfNeeded() }
        let scale = max(parentWindowRef?.backingScaleFactor ?? 2, 1)
        // Whole device pixels, so the edge `origin(for:)` puts on the target stays there. The content's own size: the
        // glass adds nothing around it, and its panel's views in the measure's temporary layout engine cost a fresh
        // solve of their constraints on every refit (a Show details press, Lawrence 2026-11-18).
        // The body's own size when it reports one and is the content's only view (a glide's leaving view sizes it too).
        let reported = leavingBody == nil ? (body as? HoverCardSizeReporting)?.reportedFittingSize : nil
        let fitting = reported ?? measuredContentSize()
        let size = CGSize(width: (fitting.width * scale).rounded(.up) / scale, height: (fitting.height * scale).rounded(.up) / scale)
        let screen = parentWindowRef?.screen ?? NSScreen.main
        let rest = Self.rest(for: placement, anchor: anchor, size: size, screen: screen?.frame,
                             visible: screen?.visibleFrame, window: parentWindowRef?.frame,
                             margin: Metrics.space2, scale: scale)
        let origin = rest.origin
        isLeading = rest.isLeading
        restingPlacement = rest.placement
        // A row card keeps its geometry (`HoverCardEscapeGeometry`: its row, frame and gap strip);
        // `rest` placed it the same way.
        escapeGeometry = placement == .besideRow
            ? HoverCardEscapeGeometry(anchor: anchor, cardSize: size,
                                      visible: screen.map { HoverCardEscapeGeometry.room(visible: $0.visibleFrame, window: parentWindowRef?.frame, margin: Metrics.space2) },
                                      scale: scale)
            : nil
        // R131: the window moves in the same frame (a window-frame slide restarted on every tab
        // trailed the pointer); a retarget's slide runs inside it (`slide(from:)`).
        restCardFrame = CGRect(origin: origin, size: size)
        if appliesFrame {
            applyRestFrame()
            bodyRests()
        }
    }

    /// Content measures the panel ran (`fittingSize`, a temporary layout engine each): tests count them.
    private(set) var contentMeasures = 0

    private func measuredContentSize() -> CGSize {
        contentMeasures += 1
        return glass.contentView.fittingSize
    }

    /// The window at the card's rest frame plus its clear band.
    func applyRestFrame() {
        let margin = Self.windowMargin
        setFrame(restCardFrame.insetBy(dx: -margin, dy: -margin), display: true)
    }

    /// Runs once the current hide has finished (ordered out); a show before then drops it.
    private var dismissCompletion: (() -> Void)?

    /// Fades the card out, then orders it out and runs `completion` (not when a show overtook
    /// the hide, or when nothing showed).
    func dismiss(completion: (() -> Void)? = nil) {
        guard isVisible, !isDismissing else {
            if !isVisible { completion?() } else if let completion { dismissCompletion = completion }
            return
        }
        isDismissing = true
        dismissCompletion = completion
        // A fading card takes no click (the pointer goes back to what is under it).
        ignoresMouseEvents = true
        Self.motion.exit(self, completion: { [weak self] in
            guard let self, self.isDismissing else { return }
            self.isDismissing = false
            self.finishMorph()
            self.endLeaving()
            self.parentWindowRef?.removeChildWindow(self)
            self.parentWindowRef = nil
            self.orderOut(nil)
            let done = self.dismissCompletion
            self.dismissCompletion = nil
            done?()
        })
    }
}

extension HoverCardPanel: ThemeResponsive {}

/// Where a card rests on screen and on which side of its target.
struct HoverCardRest: Equatable {
    var origin: CGPoint
    var placement: HoverCardPlacement
    /// The card's trailing edge is on its target's side: left of a row, or a tab card lined up
    /// with its tab's trailing edge (the morph and the entrance grow from that side).
    var isLeading = false
}

extension HoverCardPanel {
    /// The card's rest place next to `anchor`, kept on `screen`: `visible` is the screen's
    /// visible frame, `window` the parent window's frame (all screen coordinates, y up).
    ///
    /// The card stays on its target, as Chrome's and Helium's tab cards do (Lawrence
    /// 2026-10-20: "Tab cards are still disjoint from the tab itself"). It may use the visible
    /// frame and the parent window's part of the screen: a full-screen window's tabs sit in the
    /// menu bar and notch band, which the visible frame leaves out, and clamping to it pushed the
    /// card down below the toolbar. A tab or chip card keeps its touching edge on the target and
    /// its leading edge on the target's, or its trailing edge on the target's when the screen
    /// ends first; with no room on its side it flips to the other side. Only a card that fits on
    /// neither side is clamped.
    static func rest(for placement: HoverCardPlacement, anchor: CGRect, size: CGSize, screen: CGRect?, visible: CGRect?,
                     window: CGRect?, margin: CGFloat, scale: CGFloat = 2,
                     rowAlignment: HoverCardEscapeGeometry.RowAlignment = .top) -> HoverCardRest {
        var origin = Self.origin(for: placement, anchor: anchor, size: size, scale: scale, rowAlignment: rowAlignment)
        guard var area = visible ?? screen else { return HoverCardRest(origin: origin, placement: placement) }
        var isLeading = false
        if let window {
            let onScreen = screen.map { window.intersection($0) } ?? window
            if !onScreen.isNull, !onScreen.isEmpty { area = area.union(onScreen) }
        }
        let room = area.insetBy(dx: margin, dy: margin)
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, room.minX), room.maxX - size.width) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, room.minY), room.maxY - size.height) }
        var side = placement
        switch placement {
        case .below, .above:
            // Leading edges aligned; trailing edges when the screen ends first.
            if origin.x + size.width > room.maxX {
                origin.x = anchor.maxX - size.width
                isLeading = true
            }
            origin.x = clampX(origin.x)
            let fitsBelow = Self.origin(for: .below, anchor: anchor, size: size, scale: scale).y >= room.minY
            let fitsAbove = Self.origin(for: .above, anchor: anchor, size: size, scale: scale).y + size.height <= room.maxY
            if placement == .below, !fitsBelow, fitsAbove { side = .above }
            if placement == .above, !fitsAbove, fitsBelow { side = .below }
            origin.y = Self.origin(for: side, anchor: anchor, size: size, scale: scale).y
            if side == placement, !(placement == .below ? fitsBelow : fitsAbove) { origin.y = clampY(origin.y) }
        case .beside:
            // Right of the row; left of it when the screen ends first. Top-aligned, and kept inside
            // the parent window as well as the screen: the What's New popover beside the Update Ready
            // card at the sidebar's foot ran off the window's bottom and covered the composer's "+"
            // (live-qa, nightly 3a63d6d, a 1100x720 window). A card taller than the window's part of
            // the screen keeps its top in that part and runs out of the window's bottom. The screen
            // wins over the window: when that would push the card off the screen's bottom (a window
            // mostly below the screen), it sits on the screen's bottom and its top rises past the
            // window's only as far as it must; a card taller than the screen sits on its bottom too.
            if origin.x + size.width > room.maxX {
                origin.x = ((anchor.minX - HoverCardEscapeGeometry.edgeGap(scale: scale)) * scale).rounded(.up) / scale - size.width
                isLeading = true
            }
            origin.x = clampX(origin.x)
            let inWindow = window.map { room.intersection($0.insetBy(dx: margin, dy: margin)) }
            if let inWindow, !inWindow.isNull, inWindow.height > 0 {
                origin.y = min(max(origin.y, inWindow.minY), inWindow.maxY - size.height)
            }
            origin.y = max(min(origin.y, room.maxY - size.height), room.minY)
        case .besideRow:
            // Beside a sidebar row, top-aligned with it and clamped into the visible frame; left of
            // the row when the screen ends first (`HoverCardEscapeGeometry`).
            let room = HoverCardEscapeGeometry.room(visible: visible ?? screen ?? area, window: window, margin: margin)
            let geometry = HoverCardEscapeGeometry(anchor: anchor, cardSize: size, visible: room, scale: scale, alignment: rowAlignment)
            origin = geometry.card.origin
            isLeading = geometry.isLeading
        }
        return HoverCardRest(origin: origin, placement: side, isLeading: isLeading)
    }

    /// The room between a card and its tab: none. The card touches its tab, so the pointer never
    /// crosses empty space between them (Lawrence 2026-10-19: "there is a gap in between ... such
    /// that there is no gap in between"). Sidebar previews also touch their row anchor.
    static let targetGap: CGFloat = 0

    /// The card's origin (screen coordinates, y up) for `placement` next to `anchor`, before
    /// the screen clamp. The touching edge is snapped to a device pixel of `scale` toward the
    /// target, so a fractional anchor overlaps it by under a pixel and never leaves a seam. A
    /// `.besideRow` card's place is `HoverCardEscapeGeometry`'s, the one rule for sidebar cards.
    static func origin(for placement: HoverCardPlacement, anchor: CGRect, size: CGSize, scale: CGFloat = 2,
                       rowAlignment: HoverCardEscapeGeometry.RowAlignment = .top) -> CGPoint {
        let scale = max(scale, 1)
        func up(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.up) / scale }
        func down(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.down) / scale }
        return switch placement {
        // The card's top edge on the tab's bottom edge (rounded up: into the tab, never below it).
        case .below: CGPoint(x: anchor.minX, y: up(anchor.minY - targetGap) - size.height)
        // The card's bottom edge on the tab's top edge (rounded down: into the tab).
        case .above: CGPoint(x: anchor.minX, y: down(anchor.maxY + targetGap))
        // The non-sidebar `.beside` card keeps its one-device-pixel breathing room. Sidebar row
        // cards use `.besideRow` and touch the row's anchor instead.
        case .beside: CGPoint(x: down(anchor.maxX + HoverCardEscapeGeometry.edgeGap(scale: scale)), y: anchor.maxY - size.height)
        // Right of the row, its top on the row's top (before any clamp or flip the screen needs).
        case .besideRow: HoverCardEscapeGeometry(anchor: anchor, cardSize: size, scale: scale, alignment: rowAlignment).card.origin
        }
    }
}
