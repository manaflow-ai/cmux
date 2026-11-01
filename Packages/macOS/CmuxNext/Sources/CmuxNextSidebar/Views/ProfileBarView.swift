import AppKit
import CmuxNextDesign

/// The space switcher at the bottom of the sidebar or under its titlebar row
/// (`sidebar.spacesPosition`, R109). Each profile keeps its name, optional
/// icon and tonal color in the shared daemon model.
///
/// cx-5k3r (Lawrence 2026-10-08, "center spaces in bottom; spaces should
/// show better"): the strip is centered on the sidebar, each space shows its
/// icon, emoji or initial in its color, the current space sits on a
/// selection-fill chip that slides to the new space on a switch, and the "+"
/// (on hover) sits right after the last space, in a slot the strip always
/// leaves free, so it never moves the strip (Lawrence 2026-10-21).
/// Too many spaces narrow the slots, then turn compact (small dots, the
/// current one full). Layers, back to front: the hover chip (this view),
/// the current-space chip (`indicator`), the marks (`marks`).
final class ProfileBarView: NSView {
    let model: SidebarModel
    var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)?

    private(set) var hovered: Int?
    private(set) var pressed: Int?
    /// Where the press on a space started (bar coordinates): a move past the threshold drags its dot.
    var pressPoint: NSPoint?
    /// The space dot being dragged (`ProfileBarView+DotDrag`); nil otherwise.
    var dotDrag: ProfileBarDotDrag?
    private var swipeTracker = ProfileSwipeTracker()
    private var wheel = SpaceWheelPager()
    private var paging = false
    static let plusIndex = -1

    /// The current space's chip; it slides on a switch.
    let indicator = ProfileBarLayerView()
    /// The spaces' marks and the "+".
    let marks = ProfileBarLayerView()

    /// Called once for a qualifying horizontal trackpad swipe over the bar.
    var onHorizontalSwipe: ((Int) -> Void)?
    /// A horizontal trackpad gesture over the bar, 1:1 like over the list
    /// (`SidebarScrollView.onHorizontalScroll`). When set, it replaces the
    /// one-step swipe.
    var onHorizontalScroll: ((ProfileSwipeTracker.Phase, CGFloat, TimeInterval) -> Void)?
    /// A mouse wheel notch over the bar, either axis: -1 or +1.
    var onWheelPage: ((Int) -> Void)?

    /// Gallery toggles for comparing Leo's two open choices. The shipped
    /// choice is the first pair: dot at rest, + on hover. Tests use the
    /// toggles to render the alternatives without changing persisted state.
    var showsDotsWhenIdle = true
    var showsPlusWhenIdle = false
    /// `sidebar.spaceSwitcher` for galleries and tests; nil reads the Debug Settings tunable.
    var switcherStyleOverride: SpaceSwitcherStyle? { didSet { relayout() } }
    /// Shows a switcher menu at a mark (tests capture it); nil pops it up under the pointer's mark.
    var presentMenu: ((NSMenu, NSRect) -> Void)?
    /// A switcher menu opened (true) or closed: the sidebar keeps its hover chrome revealed meanwhile.
    var onMenuOpenChange: ((Bool) -> Void)?
    /// The mark whose switcher menu is open: it stays lit until the menu closes.
    var menuOpenIndex: Int?
    /// Redraws the window marks when another window switches space or the tunable changes.
    var markObservation: Task<Void, Never>?

    init(model: SidebarModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Strings.profiles)
        setAccessibilityIdentifier("cmux.sidebar.spaces")
        indicator.onDraw = { [weak self] _ in self?.drawIndicator() }
        marks.onDraw = { [weak self] _ in self?.drawMarks() }
        indicator.isHidden = true
        marks.autoresizingMask = [.width, .height]
        addSubview(indicator)
        addSubview(marks)
    }

    /// The window marks observe only while the bar is in a window: leaving it stops the observation.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        markObservation?.cancel()
        markObservation = window == nil ? nil : observeWindowMarks()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Like every sidebar control, the first click on a window that is not
    /// key switches the space instead of only activating the window (cx-i3ra).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    private var slot: CGFloat { Metrics.roomDotSlot }
    /// The pointer is over the bar: the "+" shows (Lawrence: only on hover,
    /// and the dots stay in place without it).
    private(set) var isPointerInside = false {
        didSet {
            guard isPointerInside != oldValue else { return }
            needsDisplay = true
            marks.needsDisplay = true
            placeIndicator(animated: false)
            rebuildToolTips()
        }
    }

    /// The strip never starts before this x (nil: the sidebar's horizontal
    /// inset). In the footer row the bar itself starts after the profile
    /// control, so the row passes 0.
    var leadingInset: CGFloat? { didSet { if leadingInset != oldValue { relayout() } } }
    /// The x the strip centers on, in this bar's coordinates (nil: the bar's
    /// middle). The sidebar passes its own middle, so the strip is centered
    /// on the sidebar even when the bar starts after the profile control.
    var centerX: CGFloat? { didSet { if centerX != oldValue { relayout() } } }

    /// Where every space and the "+" sit now.
    var strip: SpaceStrip {
        ProfileBarLogic.strip(count: model.profiles.count, active: activeIndex, width: Double(bounds.width),
                              center: Double(centerX ?? bounds.width / 2),
                              minLeading: Double(leadingInset ?? SidebarStyle.horizontalInset),
                              slot: Double(slot), plus: Double(model.profiles.count == 1 ? 0 : slot),
                              fullMinimum: Double(Metrics.roomDotSlot * 0.75), compactMinimum: Double(Metrics.roomDotDiameter + Metrics.space1))
    }

    private var activeIndex: Int? { model.profiles.firstIndex { $0.id == model.activeProfileID } }

    private func relayout() {
        needsDisplay = true
        marks.needsDisplay = true
        placeIndicator(animated: false)
        rebuildToolTips()
        rebuildAccessibility()
    }

    override func layout() {
        super.layout()
        marks.frame = bounds
        placeIndicator(animated: false)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            if let chip = hoverChip {
                chip.fill.setFill()
                let radius = SidebarStyle.rowCornerRadius
                NSBezierPath(roundedRect: chip.rect, xRadius: radius, yRadius: radius).fill()
            }
        }
    }

    /// The current space's chip in this bar: its slot inset like the hover
    /// chip. Nil when no current space is drawn.
    var indicatorRect: NSRect? {
        guard let active = activeIndex, dotIsDrawn(at: active) else { return nil }
        let rects = slotRects()
        guard rects.indices.contains(active) else { return nil }
        return ProfileBarLogic.chipRect(slot: rects[active], inset: Metrics.space1)
    }

    // theme-scoped: indicator.draw runs inside the bar's theme scope
    private func drawIndicator() {
        performWithTheme {
            Palette.selectionFill.setFill()
            let radius = SidebarStyle.rowCornerRadius
            NSBezierPath(roundedRect: indicator.bounds, xRadius: radius, yRadius: radius).fill()
        }
    }

    /// Moves the chip to the current space; a switch slides it (Reduce
    /// Motion and speed "off" snap, `Motion.set`).
    private func placeIndicator(animated: Bool) {
        // The dots are layers of their own while one is dragged: the current one carries the chip.
        if dotDrag != nil {
            indicator.isHidden = true
            return
        }
        // A switch not yet shown (`refresh` slides it): a relayout first
        // would snap the chip to the new space and leave nothing to slide.
        if !animated, shownActive != nil, model.activeProfileID != shownActive, !indicator.isHidden { return }
        guard let rect = indicatorRect else {
            indicator.isHidden = true
            return
        }
        let wasHidden = indicator.isHidden
        indicator.isHidden = false
        guard animated, !wasHidden, let layer = indicator.layer, indicator.frame.size == rect.size else {
            // A resize or relayout lands at once; a slide still running
            // toward the same rect keeps going.
            if indicator.frame != rect {
                indicator.layer?.removeAnimation(forKey: "position")
                indicator.frame = rect
                indicator.needsDisplay = true
            }
            return
        }
        let from = Motion.presentationValue(layer, "position")
        indicator.frame = rect
        Motion.sidebar.set(layer, "position", to: layer.position, spring: .selection, from: from)
    }

    // theme-scoped: marks.draw runs inside the bar's theme scope
    private func drawMarks() {
        performWithTheme {
            let rects = slotRects()
            let strip = strip
            for offset in drawnDotIndices {
                let profile = model.profiles[offset]
                let active = profile.id == model.activeProfileID
                draw(profile: profile, in: rects[offset], active: active, hovered: hovered == offset,
                     compact: strip.compact && !active)
                drawWindowMark(for: profile, in: rects[offset], compact: strip.compact && !active)
            }
            if plusIsDrawn { drawPlus(in: rects[model.profiles.count]) }
        }
    }

    /// The space the bar last drew as active: a change slides the chip.
    private var shownActive: ProfileKey?

    func refresh() {
        // A switch slides the current-space chip and crossfades the marks'
        // opacity; no mark moves while the strip fits (Leo 2026-10-07: no
        // size or position jump). Reduce Motion snaps.
        let switched = model.activeProfileID != shownActive && shownActive != nil
        if model.activeProfileID != shownActive {
            shownActive = model.activeProfileID
            if switched, let layer = marks.layer, let old = layer.contents {
                marks.display()
                if let new = layer.contents { _ = Motion.sidebar.set(layer, "contents", to: new, fade: .crossfade, from: old) }
            }
        }
        needsDisplay = true
        marks.needsDisplay = true
        placeIndicator(animated: switched)
        rebuildToolTips()
        rebuildAccessibility()
    }

    private func rebuildToolTips() {
        let rects = slotRects()
        var regions: [(rect: NSRect, text: String)] = drawnDotIndices.map { offset in
            let profile = model.profiles[offset]
            let name = profile.iconIsEmoji ? [profile.icon, profile.name].compactMap(\.self).joined(separator: " ") : profile.name
            return (rects[offset], windowMarkLabel(name, for: profile))
        }
        if plusIsDrawn { regions.append((rects[model.profiles.count], Strings.newProfile)) }
        setThemedToolTipRegions(regions)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { setHovered(interactionIndex(at: convert(event.locationInWindow, from: nil))) }
    override func mouseEntered(with event: NSEvent) { isPointerInside = true }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
        isPointerInside = false
    }

    /// The pointer entered or left (tests and the hover state of a drag).
    func setPointerInside(_ inside: Bool) { isPointerInside = inside }

    func setHovered(_ value: Int?) {
        // A mark whose menu is open stays lit until it closes (rulebook: hover-revealed controls stay lit).
        let value = menuOpenIndex ?? value
        guard hovered != value else { return }
        hovered = value
        needsDisplay = true
        marks.needsDisplay = true
    }

    /// The hovered space's background (F2): its rect and fill; nil when no
    /// space is hovered.
    var hoverChip: (rect: NSRect, fill: NSColor)? {
        guard let hovered else { return nil }
        let rects = slotRects()
        let index = hovered == Self.plusIndex ? model.profiles.count : hovered
        guard rects.indices.contains(index) else { return nil }
        let fill = performWithTheme { pressed == hovered ? Palette.pressedFill : Palette.hoverFill }
        return (ProfileBarLogic.chipRect(slot: rects[index], inset: Metrics.space1), fill)
    }

    /// A press on a space (tests; the mouse sets it in `mouseDown`).
    func setPressed(_ value: Int?) {
        pressed = value
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressPoint = point
        setPressed(interactionIndex(at: point))
    }

    /// A press on a space that moves drags its dot to reorder the spaces (`ProfileBarView+DotDrag`).
    override func mouseDragged(with event: NSEvent) {
        dragDot(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            pressPoint = nil
            needsDisplay = true
        }
        // A dragged dot drops (over the footer band it moves its space); the release is no click.
        if dropDot() { return }
        guard let pressed, pressed == interactionIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        activate(pressed, option: event.modifierFlags.contains(.option))
    }

    /// The bar is the pager's dots: a trackpad pages over it like over the
    /// list, and a mouse wheel pages on either axis (nothing here scrolls).
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, let phase = Self.phase(of: event) else {
            if let onWheelPage, !event.hasPreciseScrollingDeltas {
                switch wheel.feed(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, time: event.timestamp, pagesVertically: true) {
                case .pass, .hold: return
                case .page(let step): return onWheelPage(step)
                }
            }
            super.scrollWheel(with: event)
            return
        }
        let step = swipeTracker.feed(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY), phase: phase)
        if let onHorizontalScroll {
            if phase == .ended || phase == .momentum {
                if paging, phase == .ended { onHorizontalScroll(.ended, 0, event.timestamp) }
                paging = false
            } else if swipeTracker.isHorizontal {
                onHorizontalScroll(paging ? .changed : .began, event.scrollingDeltaX, event.timestamp)
                paging = true
            }
        } else if let step {
            onHorizontalSwipe?(step)
        }
        if !swipeTracker.isHorizontal { super.scrollWheel(with: event) }
    }

    private static func phase(of event: NSEvent) -> ProfileSwipeTracker.Phase? {
        if !event.momentumPhase.isEmpty { return .momentum }
        if event.phase.contains(.began) { return .began }
        if event.phase.contains(.changed) { return .changed }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return .ended }
        return nil
    }

    /// A click on a mark: the "+" makes a space; a space switches here, or, when another window shows it,
    /// offers Go to Window / Move Here (`SpaceSwitcherLogic.click`, `ProfileBarView+Windows`).
    func activate(_ index: Int, option: Bool = false) {
        if index == Self.plusIndex { return model.send(.newProfile) }
        guard model.profiles.indices.contains(index) else { return }
        click(index, option: option)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-click still edits the space underneath a shared + slot.
        let point = convert(event.locationInWindow, from: nil)
        guard let index = slotRects().dropLast().firstIndex(where: { $0.contains(point) }) else { return nil }
        return contextMenuProvider?(.profile(model.profiles[index].id))
    }

    // MARK: Accessibility

    private func rebuildAccessibility() {
        let rects = slotRects()
        var children: [NSAccessibilityElement] = model.profiles.enumerated().map { offset, profile in
            let active = profile.id == model.activeProfileID
            let element = ProfileDotElement(label: windowMarkLabel(active ? Strings.profileCurrent(profile.name) : profile.name, for: profile),
                                            frame: rects[offset], parent: self) { [weak self] in self?.activate(offset) }
            element.setAccessibilityIdentifier("cmux.sidebar.space.\(profile.id.rawValue)")
            element.setAccessibilitySelected(active)
            return element
        }
        let plus = ProfileDotElement(label: Strings.newProfile, frame: rects[model.profiles.count], parent: self) { [weak self] in
            self?.activate(Self.plusIndex)
        }
        plus.setAccessibilityIdentifier("cmux.sidebar.space.new")
        children.append(plus)
        setAccessibilityChildren(children)
    }
}
