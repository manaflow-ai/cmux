import AppKit
import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeups
import QuartzCore

/// The tab strip's wheel and trackpad scroll by translation, as Chrome scrolls its tab
/// strip: `TabStripScrollContainer` (chrome/browser/ui/views/tabs/tab_strip_scroll_container.cc) holds the
/// tabs in a `views::ScrollView` that scrolls with layers (ui/views/controls/scroll_view.cc,
/// `ScrollsWithLayers`): a scroll moves the contents layer and lays nothing out.
///
/// With ``frames`` (feature `tabStripScrollFrames`), wheel deltas arrive on the window's
/// `FrameInputCoalescer`, at most twice per frame, summed per scroll phase. The cells keep the frames
/// `applyFrames` wrote at ``laidOutOffset``; the scrolling layer's bounds origin carries the rest of the
/// scroll (``translation``), one property per frame with actions off. The strip lays out again only when the
/// set of tabs in view changes, when the + must move, during a drag, at a gesture's end, and before input
/// that starts from a tab's frame (a press, a menu, a rename, VoiceOver); hit tests and hover-card anchors
/// read the translation (``shownFrame(_:presented:)``), so the hover follows the scroll every frame. Without
/// frames each wheel event scrolls and lays out at once.
@MainActor final class TabStripScroller {
    private weak var strip: TabStripView?
    /// The strip's scrolling layer (`TabStripView.scrollingLayer`): its bounds origin carries the translation.
    private let scrollingLayer: CALayer
    /// Made in `init`, once its closure may capture the scroller.
    private var wheel: PointerFrameWheel?
    /// The scroll offset the cells' frames were last written at (`applyFrames`).
    private(set) var laidOutOffset: CGFloat = 0
    /// What the scrolling layer's bounds origin moves its cells by now (the scroll since they were laid out).
    private(set) var translation: CGFloat = 0
    /// The tabs' trailing edge at the last layout: where the + follows them.
    private var laidOutTrailing: CGFloat = 0
    /// The slots (indices into the layout's slots) the unpinned region showed at the last layout.
    private var laidOutSpan: Range<Int> = 0..<0
    /// The hover card was dismissed for the scroll gesture in progress.
    private var dismissedCard = false
    /// Translations set (debug and tests: one per frame of scroll, none for a layout).
    private(set) var translationSets = 0

    init(strip: TabStripView) {
        self.strip = strip
        scrollingLayer = strip.scrollingLayer
        wheel = PointerFrameWheel(owner: "TabStripView.wheel", view: strip) { [weak self] delivery in self?.scroll(delivery) }
    }

    /// The windows' frame-aligned wheels (feature `tabStripScrollFrames`); nil: each wheel event scrolls and
    /// lays out at once.
    var frames: FrameInputCoalescers? {
        get { wheel?.frames }
        set { wheel?.frames = newValue }
    }

    /// Wheel scrolls wait for the frame (debug and tests).
    var hasPending: Bool { wheel?.hasPending ?? false }

    /// `layer`'s frame in the tabs' clip as it shows now: a layer of the scrolling layer moves with the scroll.
    /// `presented`: with every move in flight (its presentation layer), else at its target.
    func shownFrame(_ layer: CALayer, presented: Bool = false) -> CGRect {
        let frame = presented ? (layer.presentation() ?? layer).frame : layer.frame
        return layer.superlayer === scrollingLayer ? frame.offsetBy(dx: -translation, dy: 0) : frame
    }

    /// A wheel or trackpad scroll over the strip; false when the tabs fit (the event goes on up).
    func scrollWheel(_ event: NSEvent) -> Bool {
        guard let strip, let wheel, strip.result.isOverflowing else { return false }
        wheel.scrolled(event)
        return true
    }

    /// Input that reads the tabs' geometry comes next (a press, a menu): the pending scrolls apply, and
    /// the cells are laid out where they show.
    func landForInput() {
        wheel?.flush()
        land()
    }

    /// Lays the cells out where they show (`applyFrames`) when a translation moved them.
    func land() {
        if translation != 0 { strip?.applyFrames() }
    }

    /// Takes the translation into the layers' positions, before a layout writes frames (in the same
    /// transaction): what they show stays, and a move starts from there.
    func landLayers() {
        let shift = translation
        guard shift != 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in scrollingLayer.sublayers ?? [] { layer.position.x -= shift }
        scrollingLayer.bounds.origin.x -= shift
        CATransaction.commit()
        laidOutOffset += shift
        translation = 0
    }

    /// `applyFrames` wrote every frame at the current offset; `trailing`: the tabs' trailing edge.
    func didLayOut(trailing: CGFloat) {
        guard let strip else { return }
        laidOutOffset = strip.scrollOffset
        translation = 0
        laidOutTrailing = trailing
        laidOutSpan = shownSpan(strip.scrollMapping, in: strip)
    }

    /// A wheel or a drag's autoscroll takes the scroll over: the scroll part of every move still in
    /// flight (a reveal's spring, a relayout that keeps the selected tab in view) ends where it shows
    /// now (the scroll offset becomes that), so nothing drifts against the gesture; the rest of a
    /// relayout (tabs making room, a close) keeps moving.
    func settle() {
        guard let strip, strip.scrollProbe.animationKeys()?.isEmpty == false else { return }
        // What the scroll parts add now (a view x is the content x minus the offset): the probe takes only them.
        let shown = MotionPath(strip.scrollProbe, "position").value(at: CACurrentMediaTime()).x
        strip.scrollOffset = TabScrollMath.clamp(strip.scrollOffset - (shown - strip.scrollProbe.position.x), contentWidth: strip.result.contentWidth,
                                                 viewportWidth: strip.viewportWidth)
        var layers = [strip.scrollProbe] + strip.cells.values.map(\.layer) + strip.groups.chips.values.map(\.layer)
        layers += strip.groups.bands.values.flatMap { [$0.washLayer, $0.lineLayer] }
        if let button = strip.newTabButton.layer { layers.append(button) }
        TabStripMove.cancelScroll(on: layers)
    }

    // MARK: - Deliveries

    /// One wheel delivery: one event, or a frame's events of one phase (the wheel calls it; tests too).
    func scroll(_ scroll: PointerFrameWheel.Scroll) { // perf-hot: 50us tab-strip-scroll
        guard let strip else { return }
        var delta = scroll.delta.dx
        // Vertical wheels scroll the strip too.
        if abs(scroll.delta.dy) > abs(delta) { delta = scroll.delta.dy }
        if !scroll.isPrecise { delta *= 12 }
        // One dismissal per gesture: the card stays away until the pointer moves. A gesture's start
        // dismisses again, so a gesture whose end was never delivered does not spare the next one.
        if scroll.startsGesture { dismissedCard = false }
        if !dismissedCard {
            dismissedCard = true
            strip.hoverCards.dismiss(.action)
        }
        settle()
        strip.scrollOffset = TabScrollMath.clamp(strip.scrollOffset - delta, contentWidth: strip.result.contentWidth, viewportWidth: strip.viewportWidth)
        // A reveal's spring the wheel ended (`settle`) moved the offset too: what shows follows both.
        if strip.scrollOffset != laidOutOffset + translation {
            if frames == nil { strip.applyFrames() } else { translate(pointer: scroll.location, in: strip) }
        }
        if scroll.endsGesture { land() }
        if scroll.endsGesture || scroll.isNotch { dismissedCard = false }
        // A notch has no gesture end to land at: its translation stays until the next input or layout, so
        // the elements' frames follow it now, once per delivery (Chrome sends accessibility location changes
        // after the frame: content/renderer/accessibility/render_accessibility_impl.cc `SendLocationChanges`).
        if scroll.isNotch, translation != 0 { writeAccessibilityFrames(in: strip) }
    }

    /// The tabs' and chips' accessibility frames where they show, the translation included.
    private func writeAccessibilityFrames(in strip: TabStripView) {
        for cell in strip.cells.values {
            cell.accessibility.setAccessibilityFrameInParentSpace(strip.tabsClip.convert(shownFrame(cell.layer), to: strip))
        }
        for chip in strip.groups.chips.values {
            chip.accessibility.setAccessibilityFrameInParentSpace(strip.tabsClip.convert(shownFrame(chip.layer), to: strip))
        }
    }

    /// Shows the scroll by translation, or lays out when the tabs in view or the + would change, or while a
    /// drag places its tabs under the pointer (it lays out every event anyway).
    private func translate(pointer: CGPoint, in strip: TabStripView) {
        let mapping = strip.scrollMapping
        let dragging = strip.drag != nil || strip.groups.drag != nil || strip.phantomPoint != nil
        guard !dragging, shownSpan(mapping, in: strip) == laidOutSpan, !plusMoves(mapping, width: strip.viewportWidth) else {
            return strip.applyFrames()
        }
        // Whole device pixels, as `cellFrame` rounds every edge: a trackpad's fractional deltas never draw
        // the cells between pixels.
        let scale = strip.window?.backingScaleFactor ?? 2
        translation = ((strip.scrollOffset - laidOutOffset) * scale).rounded() / scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollingLayer.bounds.origin.x = mapping.band + translation
        CATransaction.commit()
        translationSets += 1
        strip.edgeFade.update()
        // The tab under a still pointer changed: the hit tests read the translation.
        let point = strip.convert(pointer, from: nil)
        let lit = strip.hoveredID != nil || strip.groups.hoveredChip != nil || strip.buttonReveal.pointerInStrip
        if lit, strip.bounds.contains(point) { strip.updateHover(at: point, moved: false) }
    }

    /// Whether the + would leave the place it was laid out at: it follows the last tab until it reaches
    /// the strip's end (`applyFrames`).
    private func plusMoves(_ mapping: TabScrollMapping, width: CGFloat) -> Bool {
        abs(min(laidOutTrailing - mapping.offset, width) - min(laidOutTrailing - laidOutOffset, width)) > 0.01
    }

    /// The slots the unpinned region shows at `mapping`'s offset; the layout's slots run left to right.
    private func shownSpan(_ mapping: TabScrollMapping, in strip: TabStripView) -> Range<Int> {
        let slots = strip.result.slots
        let low = mapping.offset + mapping.band, high = mapping.offset + strip.viewportWidth
        let end = Self.firstIndex(in: slots) { $0.x >= high }
        return min(Self.firstIndex(in: slots) { $0.maxX > low }, end)..<end
    }

    /// The first slot from which `isAfter` holds (it holds for every later slot), by bisection.
    private static func firstIndex(in slots: [TabLayoutSlot], where isAfter: (TabLayoutSlot) -> Bool) -> Int {
        var low = 0, high = slots.count
        while low < high {
            let mid = (low + high) / 2
            if isAfter(slots[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
