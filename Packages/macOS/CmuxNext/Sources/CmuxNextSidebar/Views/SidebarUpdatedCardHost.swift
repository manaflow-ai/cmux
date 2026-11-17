import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups

/// The "cmux Updated!" card's slot view: the updated surface, sized to the page's
/// height, and the card's x. Hidden without a card or a surface.
///
/// The page paints the card's glass: the agent composer's material and one-line
/// height (webviews `ui/glass/composerMaterial.css`), so the card beside the
/// composer has its edge, fill and height (Leo 2026-11-07: "the border styles, the
/// glass intensity is different. For two, it's like the heights never match up
/// with anything"). The fill is translucent, as the sidebar cards' native veil
/// was (Leo 2026-10-30: "I don't like the non-glassness"), and opaque only under
/// Reduce Transparency.
///
/// Under the page this view draws the frost (``glass``): the page's own blur
/// cannot reach the native rows the open preview and a dragged card stand over,
/// so the card stays glass over them, with their motion showing through, instead
/// of turning solid (Leo 2026-11-08: "it turns from glass when it's unhovered into
/// opaque when it does get hovered. I feel like we should be able to keep it as
/// glass though, right?"). It is the card's size and its open preview's, and runs
/// the page's preview motion with it (``MotionGate/cardCurve``).
///
/// Resting on the card opens its changes beside the sidebar, in the app's one hover card window
/// (``SidebarUpdatedNotesPopover``; Lawrence 2026-11-07, on the list that grew up over the
/// sidebar: "i dont like how it expands upwards"). The look before, kept as a Debug choice
/// (``UpdatedCardPreviewMode/above``), opens a hover preview in the card itself, a scrollable list
/// of the update's changes in the same glass (Leo 2026-11-07: "a quick access scroll through of
/// what's new. Right in that bottom left of the sidebar area"). The page decides
/// when (it hears the pointer from this view's tracking area,
/// ``SidebarSurfaceIsland/setPointerInside(_:)``) and asks for the room above the
/// card (``overlayHeight``); the view then grows upward over the sidebar's list,
/// without moving the list, and the page's card stands on its bottom edge.
///
/// The x is native, over the page's top right, shown while the pointer is on
/// the card (Lawrence 2026-10-23: "i cant X this out anymore even when hovering
/// on it"). It was the page's own button: WebKit tracks the pointer and takes a
/// first click only in the key window, and since the agent chat, New Tab and
/// Home run in Chromium (69a51bf63be, 95b8716297c) a Chromium page's own child
/// window holds the key while the person works there, so the page never showed
/// its x and ate the click. A native tracking area and a button that takes the
/// first click work whichever of the app's windows has the key, as the media
/// card's x does.
final class SidebarUpdatedCardHost: NSView {
    private(set) var card: SidebarUpdatedCard?
    /// The page's height changed: the sidebar lays the slot out again.
    var onHeightChange: (() -> Void)?
    /// The card's x (u2441): the slot sends `.dismissUpdated`, as every card's x sends its intent.
    var onDismiss: (() -> Void)?
    /// The x: shown while the pointer is on the card. A step larger than the other cards' (Leo
    /// 2026-11-07: "maybe you could even make the close button a bit bigger").
    let closeButton = SidebarIconButton(icon: .actionClose, pointSize: { 10 }, label: "")
    /// The pointer is on the card: its x shows.
    private(set) var isHovered = false
    /// The hover owner (`PointerHover`): hover is where the pointer is now, over the card's glass or its
    /// closing preview, recomputed whenever the glass moves. A tracking area on the whole view, room
    /// included, sent no exit when the view shrank under a still pointer, so the page kept hearing
    /// "inside" over the rows and reopened the list (Leo 2026-11-08: "flicker upon hovering over what's new").
    private var pointerHover: PointerHover?
    /// The frost behind the page: the card and its open preview, at the composer's corner. Only the
    /// material: the page paints the composer's tint over it.
    let glass = GlassPanelView(cornerRadius: LayoutGrid.composerRadius) // glass-level-allow: the material only; the page paints the composer's popover-level tint over it
    /// The glass's frame for the preview height it was last laid out at.
    private(set) var glassFrame = NSRect.zero
    /// The glass's frame before a close that is still running: the preview still shows there, so the
    /// card keeps the pointer over it until the close ends (review F1 of #38117's third pass).
    /// Kept as a height from the card's resting edge, so a relayout mid-close (a sidebar resize) moves
    /// it with the card instead of dropping it (review F2 of #38222).
    var closingFrame: NSRect? {
        closingHeight.map { NSRect(x: 0, y: anchor == .top ? 0 : bounds.height - $0, width: bounds.width, height: $0) }
    }
    private var closingHeight: CGFloat?
    /// Counts preview motions: only the close that is still the latest ends the hold (review F1 of #38222).
    private var glassMotion = 0
    private var glassPreview: CGFloat = 0
    /// Makes ``island`` once a card shows (a web page; none at launch without one).
    var surfaces: (any SidebarUpdateSurfaces)? {
        didSet {
            island?.close()
            pageReported = false
            island = card == nil ? nil : surfaces?.island(.updated)
            notes.tearDown()
            notes.surfaces = surfaces
            prepareNotes()
            isHidden = card == nil || island == nil
        }
    }
    /// The card's changes beside the sidebar (``UpdatedCardPreviewMode/beside``, the shipped look).
    let notes = SidebarUpdatedNotesPopover()
    /// Where the card shows its changes, read when the card shows (Debug Settings
    /// `sidebar.updatedCard.preview`; the page reads the same look from the theme).
    private(set) var previewMode = UpdatedCardPreviewMode.shipped

    /// Makes (or closes) the changes' popover page for the card's look.
    private func prepareNotes() {
        notes.prepare(in: self, enabled: card != nil && previewMode.opensBeside)
    }
    var island: (any SidebarSurfaceIsland)? {
        didSet {
            oldValue?.view.removeFromSuperview()
            guard let island else { return }
            island.view.frame = bounds
            island.view.autoresizingMask = [.width, .height]
            // Undrawn until the page reports its words (``drawn``).
            island.view.alphaValue = drawn ? 1 : 0
            // Over the glass and under the x: the page never covers it.
            addSubview(island.view, positioned: .above, relativeTo: glass)
            island.onHeightChange = { [weak self] in self?.pageDidReportHeight() }
            island.onDismiss = { [weak self] in self?.onDismiss?() }
            island.onDrag = { [weak self] in self?.pageDragged($0) }
        }
    }

    /// Where the card rests (``SidebarUpdatedCardHost+Drag``), kept across launches.
    var anchor = SidebarUpdatedCardHost.rememberedAnchor
    /// How far the page holds the card from its rest while it is dragged; nil when not held.
    var heldOffset: CGPoint?
    /// Where the card was shown, from its rest, when the drag took it: a press while it still sprang to
    /// its place (review F2 of #37669). The page's offset counts from the press, so it adds to this.
    var heldBase = CGPoint.zero
    /// Where the card's view was when it was let go, until the next layout springs it from there.
    var droppedAt: CGPoint?
    /// The dropped card's way from where it was let go to its rest (each springs to 0).
    let settleX = SidebarCardSlotMotion(), settleY = SidebarCardSlotMotion()
    /// The card was hidden while held: the page's moves and release for that press are dropped until
    /// its release (``hideEndsDrag()``).
    var dropsHiddenDrag = false

    /// The height the card's page last reported, kept across launches: a relaunch after an update
    /// lays the card out at it in its first frame instead of making room once the page has drawn
    /// (Leo 2026-11-04: "i feel like the restarted after nightly update does too many layout
    /// shifts/flicker renderings"). The card's words and its shape change little between builds, so
    /// the previous build's height is the guess when this build's card has not drawn yet.
    ///
    /// The keys are the composer-height card's own (`.v2`): the two-line card before it remembered 64 and
    /// 77 pt, which held a tall view around the 48 pt card after the upgrade (review F1 of #37615). The old
    /// keys are read by nothing and removed at the first write (``legacyHeightKeys``).
    ///
    /// The heights are the page's CSS pixels, free of the interface scale: points divided by `app.uiScale`
    /// when written, times the scale now when read (``rememberedHeight(width:)``), so a 60 pt card
    /// remembered at 125% is held at 48 the next launch at 100% (review F1 of #38150). The `.v2` keys held
    /// points at a scale they never wrote down, so they are dropped, not read as 100%: a guess too large
    /// would hold a too-tall card for the whole showing, while no remembered height costs one launch's
    /// first-frame room.
    static let rememberedHeightKey = "cmux.sidebar.updatedCard.height.v3"
    /// The heights the card's page last reported at each card width, newest first (`[width, height]`
    /// pairs, at most ``rememberedWidthsLimit``). Windows with sidebars of different widths wrap the
    /// card's words on different lines (the relaunch bench at 7ed8d1ffedd: 77 pt at 196 pt wide, 64 pt
    /// at 300), so one height for every window moved the other window's card after its first frame.
    static let rememberedHeightsKey = "cmux.sidebar.updatedCard.heights.v3"
    /// The keys the card wrote its heights under before: the two-line card's, then the composer-height
    /// card's points at an unrecorded scale (`.v2`).
    static let legacyHeightKeys = ["cmux.sidebar.updatedCard.height", "cmux.sidebar.updatedCard.heights",
                                   "cmux.sidebar.updatedCard.height.v2", "cmux.sidebar.updatedCard.heights.v2"]
    static let rememberedWidthsLimit = 8

    /// The height the page last reported at `width` (whole points), else the last one at any width
    /// (``rememberedHeightKey``, which builds before the per-width heights wrote too), in points at the
    /// interface scale now; 0 when it never drew.
    static func rememberedHeight(width: CGFloat) -> CGFloat {
        let key = Double(width.rounded())
        let css = rememberedHeights.first(where: { $0[0] == key })?[1] ?? UserDefaults.standard.double(forKey: rememberedHeightKey)
        return max(0, points(css: css))
    }

    /// The interface scale heights are remembered against (never 0).
    private static var scale: Double { max(Double(DesignSettings.shared.uiScale), 0.01) }

    /// `css` pixels in points at the scale now, to a thousandth (no float noise from the round trip).
    private static func points(css: Double) -> CGFloat {
        CGFloat((css * scale * 1000).rounded() / 1000)
    }

    private static var rememberedHeights: [[Double]] {
        (UserDefaults.standard.array(forKey: rememberedHeightsKey) as? [[Double]])?.filter { $0.count == 2 } ?? []
    }

    /// Keeps `height` (points at the scale now) as CSS pixels at `width`.
    private static func remember(height points: CGFloat, width: CGFloat) {
        let height = (Double(points) / scale * 1000).rounded() / 1000
        let defaults = UserDefaults.standard
        for key in legacyHeightKeys where defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
        if Double(height) != defaults.double(forKey: rememberedHeightKey) { defaults.set(Double(height), forKey: rememberedHeightKey) }
        guard width > 0 else { return }
        let key = Double(width.rounded())
        let pairs = rememberedHeights
        if pairs.first == [key, Double(height)] { return }
        let kept = [[key, Double(height)]] + pairs.filter { $0[0] != key }
        defaults.set(Array(kept.prefix(rememberedWidthsLimit)), forKey: rememberedHeightsKey)
    }

    /// The card's width in the slot (the sidebar's width less the slot's insets), set by the slot
    /// before it asks for ``height``: the remembered height is the one at this width.
    var slotWidth: CGFloat = 0 {
        // A resized sidebar wraps the words anew: the first frame's height no longer holds.
        didSet { if oldValue > 0, oldValue != slotWidth { heldHeight = 0 } }
    }

    /// The height the card showed in its first frame (its remembered height at its width), kept until
    /// the card goes: the page's later, smaller reports (the host's items at the 1.5 s settle, before
    /// the span's notes arrive; words shorter than last launch's) never shrink it, and a report the
    /// height already holds moves nothing (Leo 2026-11-04: "i feel like the restarted after nightly
    /// update does too many layout shifts/flicker renderings"). The words draw at the card's top, inside
    /// the glass. A report taller than it still grows the card. 0: nothing held (no remembered height,
    /// or the sidebar's width changed).
    private(set) var heldHeight: CGFloat = 0
    /// The interface scale ``heldHeight`` was taken at: the page's points follow a live scale change, so
    /// the hold does too (a card held at 60 at 125% holds 48 at 100%, never its old, larger height).
    private var heldScale: CGFloat = 1
    /// The hold was armed for this showing of the card (once: a resize releases it, never re-arms it).
    private var holdArmed = false
    /// A height the page reported before the card's width was known: remembered at that width once the
    /// slot gives it (``holdFirstFrame()``), after the hold has read the height remembered before it.
    private var pendingRememberedHeight: CGFloat?
    /// The one armed observation of `app.uiScale` (``observeScale()``).
    private let scaleTracking = SingleArmedTracking()

    /// Holds the first frame's height: the slot calls it once it has set ``slotWidth``, before it reads
    /// ``height``. Armed at the card's first layout whether or not the page has reported yet: a report
    /// can land before the sidebar has laid out once (review F1 of #36248, #36267), and the first frame
    /// is still the one this layout draws.
    func holdFirstFrame() {
        guard card != nil, island != nil, slotWidth > 0 else { return }
        observeScale()
        if !holdArmed {
            holdArmed = true
            (heldHeight, heldScale) = (Self.rememberedHeight(width: slotWidth), DesignSettings.shared.uiScale)
        }
        if let pending = pendingRememberedHeight {
            pendingRememberedHeight = nil
            Self.remember(height: pending, width: slotWidth)
        }
    }

    /// Lays the card out again when `app.uiScale` changes: its hold and remembered height are read at the
    /// scale now, and before the page's first report nothing else tells the sidebar (review F2 of #38150).
    /// One registration at a time, re-armed by the layout the change asks for; it stops when the host goes
    /// (weak) or the card does (``holdFirstFrame()`` runs only while a card shows).
    private func observeScale() {
        _ = scaleTracking.track(shape: []) {
            DesignSettings.shared.uiScale
        } onChange: { [weak self] in
            // Inside the setting's write: the layout this asks for reads the new scale.
            MainDelivery().run {
                guard let self, self.card != nil else { return }
                self.needsLayout = true
                self.onHeightChange?()
            }
        }
    }

    /// The card's next height lands at once: its first layout (at the remembered height) and the
    /// page's first report (its real one). The list then has its final room in the frame the card
    /// shows, never on a spring; later changes (the notes of a new build) still spring.
    private(set) var landsAtOnce = false
    /// The page has reported a height since the card showed.
    private var pageReported = false {
        didSet { if pageReported != oldValue { showDrawn() } }
    }

    /// The card draws (its glass, its page and its x) once its page has reported its words: before
    /// that the page is still loading and the glass would stand blank for up to a second at launch
    /// (Leo 2026-11-09: "it should have the updated to Nightly already loaded in, instead of just
    /// having a blank glass bit"). The page reports as soon as it has the host's data, its title
    /// final and its change line a quiet loading line one line tall (webviews surface.tsx), so the
    /// card appears whole. The room is the card's from its first frame all the same (``height``).
    var drawn: Bool { pageReported }

    /// Shows or hides the glass and the page for ``drawn``, together and without motion.
    private func showDrawn() {
        Motion.withoutAnimation { island?.view.alphaValue = drawn ? 1 : 0 }
        needsLayout = true
        pointerHover?.refresh()
    }

    /// The sidebar laid the card out at its height without motion.
    func landed() { landsAtOnce = false }

    private func pageDidReportHeight() {
        if !pageReported { (pageReported, landsAtOnce) = (true, true) }
        if let height = island?.contentHeight, height > 0 {
            // Before the first layout the width is unknown, and writing now would replace the height the
            // hold is about to read: the slot remembers it once it has armed the hold.
            if slotWidth > 0, holdArmed { Self.remember(height: height, width: slotWidth) } else { pendingRememberedHeight = height }
        }
        // A preview that opens or closes changes no frame: the glass follows it in this view's layout.
        needsLayout = true
        onHeightChange?()
    }

    /// The card's sizes at the sidebar's density (Lawrence 2026-11-01: "the card must reflect my
    /// compactness level"): the page reads the same ones (`--cmux-sidebar-card-*`, WebTheme).
    static var metrics: SidebarCardMetrics { SidebarRowTokens.current.card }
    /// The x's side and its inset from the card's top right: on the title line, inside the padding.
    static var closeSide: CGFloat { metrics.closeSide }
    static var closeInset: NSSize {
        let m = metrics
        return NSSize(width: max(m.paddingX - 2, 0), height: max(m.paddingY - 2, 0))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        setAccessibilityElement(false)
        closeButton.showsLabelToolTip = false
        // A light x: a round hover fill, never a box (Lawrence 2026-11-07, "the X sits in a heavy box").
        closeButton.isRound = true
        closeButton.takesKeyFocus = true
        closeButton.takesFirstClick = true
        closeButton.setAccessibilityIdentifier("cmux.sidebar.updated.close")
        closeButton.onPress = { [weak self] in self?.onDismiss?() }
        closeButton.isHidden = true
        closeButton.alphaValue = 0
        glass.isHidden = true
        addSubview(glass)
        let hover = PointerHover(self) { [weak self] hovering in self?.setHovered(hovering) }
        hover.region = { [weak self] _ in
            guard let self, drawn else { return .zero }
            return closingFrame.map { glassFrame.union($0) } ?? glassFrame
        }
        pointerHover = hover
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    /// Shows the card (the page draws its text), or hides the view and
    /// closes its page.
    func configure(_ card: SidebarUpdatedCard?) {
        guard card != self.card else { return }
        // A card that shows (at launch, after the update) takes its room at once.
        if card != nil, self.card == nil { (landsAtOnce, pageReported, heldHeight, holdArmed, pendingRememberedHeight) = (true, false, 0, false, nil) }
        if card != nil, self.card == nil { previewMode = UpdatedCardPreviewMode.tunable.value }
        self.card = card
        closeButton.label = card?.dismissLabel ?? ""
        if card != nil, island == nil { island = surfaces?.island(.updated) }
        prepareNotes()
        if card == nil {
            if let island {
                // The card went away (dismissed): its page goes too (cx-asynu).
                island.close()
                self.island = nil
            }
            (heldHeight, holdArmed, pendingRememberedHeight) = (0, false, nil)
            (heldOffset, heldBase, droppedAt) = (nil, .zero, nil)
            // Its page went with it: no late drag message of the old page will come.
            dropsHiddenDrag = false
            // A card that comes back starts at its rest, not on the way from an old drop.
            settleX.reset()
            settleY.reset()
            // A card that comes back starts without its x until the pointer moves onto it.
            isHovered = false
            setHoverShown(closeButton, false, fades: false)
        }
        isHidden = card == nil || island == nil
    }

    /// The card's height: the page's content height once it has reported one, never less than the
    /// height its first frame held (``heldHeight``; 0 for a page with nothing to show, which hides the
    /// card), and until then the height it last reported
    /// at this card's width (``rememberedHeight(width:)``; 0 when it never drew), so the room is there from the first frame and
    /// the words fill in where they stay.
    /// ``heldHeight`` at the interface scale now.
    private var held: CGFloat {
        let scale = DesignSettings.shared.uiScale
        return scale == heldScale || heldScale <= 0 ? heldHeight : (heldHeight * scale / heldScale).rounded(.up)
    }

    var height: CGFloat {
        guard card != nil, let island else { return 0 }
        guard pageReported else {
            return heldHeight > 0 ? held : Self.rememberedHeight(width: slotWidth > 0 ? slotWidth : bounds.width)
        }
        let content = island.contentHeight
        return content > 0 ? max(content, held) : 0
    }

    /// Shows the x while the pointer is on the card, with the hover-reveal fade (instant under Reduce
    /// Motion), and tells the page, which opens the hover preview after the dwell.
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        setHoverShown(closeButton, hovered && card != nil, fades: window != nil)
        island?.setPointerInside(hovered && card != nil)
        notes.cardHovered(hovered && card != nil)
    }

    /// A hidden card is not under the pointer: hidden by the slot (a card of higher priority took it)
    /// or with no card, its x hides and the page hears the pointer leave, so it closes the preview and
    /// hands the room back, and the card comes back closed (review F3 of #37615).
    override var isHidden: Bool {
        didSet {
            if isHidden, !oldValue {
                pointerLeft()
                notes.hide()
                hideEndsDrag()
            }
            pointerHover?.refresh()
        }
    }

    private func pointerLeft() {
        guard isHovered else { return }
        isHovered = false
        setHoverShown(closeButton, false, fades: false)
        island?.setPointerInside(false)
        notes.cardHovered(false)
    }

    /// The room the open hover preview needs from the card's resting edge (the card and the preview's
    /// rows): above the bottom slot's bottom, or below the top place's top; 0 while it is closed.
    var overlayHeight: CGFloat {
        guard card != nil, let island else { return 0 }
        return island.overlayHeight
    }

    /// The view's height in the slot: the card's, or the open preview's room when that is taller. The
    /// slot keeps only ``height`` of room; the rest stands over the list.
    var frameHeight: CGFloat { max(height, overlayHeight) }

    /// The hover preview is open: the page asked for room past the card's own height.
    var previewIsOpen: Bool { overlayHeight > height + 0.5 }

    /// The x's top: centered on the card's title line (the first of its two centered lines), inside
    /// the card's own height. The title line leads the card's lines at the view's top for a card
    /// resting at the top, and while the hover preview is open (the page lays its header first,
    /// Lawrence 2026-11-07: "a header (Updated to <version>, What's New link, close), then the
    /// items"); else it is at the bottom of the view.
    var closeTop: CGFloat {
        let m = Self.metrics, card = height > 0 ? height : bounds.height
        let titleCenter = card / 2 - (m.gap + m.noteSize * 1.3) / 2
        let headerOnTop = anchor == .top || previewIsOpen
        return (headerOnTop ? 0 : bounds.height - card) + max(Self.closeInset.height, (titleCenter - Self.closeSide / 2).rounded())
    }

    /// Whether the x shows now (proofs).
    var closeShown: Bool { !closeButton.isHidden && closeButton.alphaValue > 0 }

    // The open preview's room grows the view upward: the x keeps its place on the card's title line.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let side = Self.closeSide
        closeButton.frame = NSRect(x: bounds.width - Self.closeInset.width - side, y: closeTop,
                                   width: side, height: side).integral
        layoutGlass()
    }

    /// The glass behind the card and its open preview, on the card's resting edge. A preview that opens
    /// or closes moves its edge on the page's curve, from the moment the page starts its motion, so the
    /// glass and the page's preview move as one; every other change (the view growing for the preview's
    /// room, the card's words) lands at once.
    private func layoutGlass() {
        let preview = card == nil ? 0 : island?.previewHeight ?? 0
        let tall = min(bounds.height, (height > 0 ? height : bounds.height) + preview)
        let next = NSRect(x: 0, y: anchor == .top ? 0 : bounds.height - tall, width: bounds.width, height: tall)
        glass.isHidden = card == nil || tall <= 0 || !drawn
        // The composer's corner at the page's zoom: the page's corner grows with the interface scale.
        glass.cornerRadius = LayoutGrid.composerRadius * (island?.zoom ?? 1)
        guard next != glassFrame else { return }
        defer { pointerHover?.refresh() }
        let moves = preview != glassPreview && window != nil && !glassFrame.isEmpty
        if preview != glassPreview {
            // A new open or close: the latest one decides what the card holds.
            glassMotion += 1
            closingHeight = moves && preview < glassPreview ? glassFrame.height : nil
        }
        (glassFrame, glassPreview) = (next, preview)
        guard moves else { return Motion.withoutAnimation { glass.frame = next } }
        let motion = glassMotion
        // The page's gate (web), not the sidebar's: with web motion off or reduced the page's preview
        // is simply there, and so is the glass (review F1 of #38117).
        Motion.web.animateCard(in: self, { glass.animator().frame = next }) { [weak self] in
            // An earlier motion's end leaves a later close's hold alone.
            guard let self, glassMotion == motion else { return }
            closingHeight = nil
            pointerHover?.refresh()
        }
    }

    /// Whether the card's glass covers `windowPoint`: the rows under it light nothing and open no card
    /// (``SidebarListView/hoverOccluded``).
    func covers(windowPoint: NSPoint) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, card != nil else { return false }
        return owns(convert(windowPoint, from: nil))
    }

    /// The card owns `point` (this view's coordinates): on its glass, or on the preview still closing.
    private func owns(_ point: NSPoint) -> Bool {
        drawn && (glassFrame.contains(point) || closingFrame?.contains(point) == true)
    }

    /// The view grown for the preview's room takes the pointer only where the card's glass is: a
    /// closing preview's room, and the room asked for before it opens, pass clicks to the rows.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, owns(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}
