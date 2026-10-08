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
/// (on hover) sits at the bar's trailing edge so it never moves the strip.
/// Too many spaces narrow the slots, then turn compact (small dots, the
/// current one full). Layers, back to front: the hover chip (this view),
/// the current-space chip (`indicator`), the marks (`marks`).
final class ProfileBarView: NSView {
    private let model: SidebarModel
    var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)?

    private var hovered: Int?
    private var pressed: Int?
    private var swipeTracker = ProfileSwipeTracker()
    private static let plusIndex = -1

    /// The current space's chip; it slides on a switch.
    let indicator = ProfileBarLayerView()
    /// The spaces' marks and the "+".
    let marks = ProfileBarLayerView()

    /// Called once for a qualifying horizontal trackpad swipe over the bar.
    var onHorizontalSwipe: ((Int) -> Void)?

    init(model: SidebarModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Strings.profiles)
        indicator.onDraw = { [weak self] _ in self?.drawIndicator() }
        marks.onDraw = { [weak self] _ in self?.drawMarks() }
        indicator.isHidden = true
        marks.autoresizingMask = [.width, .height]
        addSubview(indicator)
        addSubview(marks)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

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
                              slot: Double(slot), plus: Double(slot),
                              fullMinimum: Double(Metrics.roomDotSlot * 0.75), compactMinimum: Double(Metrics.roomDotDiameter + Metrics.space1))
    }

    private var activeIndex: Int? { model.profiles.firstIndex { $0.id == model.activeProfileID } }

    /// One rect per space (in order), then the "+" rect.
    func slotRects() -> [NSRect] {
        let strip = strip
        return (strip.slots + [strip.plus]).map { NSRect(x: $0.x, y: 0, width: $0.width, height: bounds.height) }
    }

    private func index(at point: NSPoint) -> Int? {
        let rects = slotRects()
        guard let hit = rects.firstIndex(where: { $0.contains(point) }) else { return nil }
        guard hit == model.profiles.count else { return hit }
        return isPointerInside ? Self.plusIndex : nil
    }

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

    /// The dots drawn now: none for a lone space at rest (it switches nothing; the bar stays
    /// mounted so the chrome never shifts), every space otherwise.
    var drawnDotCount: Int {
        ProfileBarLogic.isVisible(profileCount: model.profiles.count) || isPointerInside ? model.profiles.count : 0
    }

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
        guard drawnDotCount > 0, let active = activeIndex else { return nil }
        let rects = slotRects()
        guard rects.indices.contains(active) else { return nil }
        return ProfileBarLogic.chipRect(slot: rects[active], inset: Metrics.space1)
    }

    /// The current space's chip fill: the row selection token (never the
    /// system blue).
    var indicatorFill: NSColor { performWithTheme { Palette.selectionFill } }

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
        Motion.set(layer, "position", to: layer.position, spring: .selection, from: from)
    }

    // theme-scoped: marks.draw runs inside the bar's theme scope
    private func drawMarks() {
        performWithTheme {
            let rects = slotRects()
            let strip = strip
            for (offset, profile) in model.profiles.enumerated().prefix(drawnDotCount) {
                let active = profile.id == model.activeProfileID
                draw(profile: profile, in: rects[offset], active: active, hovered: hovered == offset,
                     compact: strip.compact && !active)
            }
            if isPointerInside { drawPlus(in: rects[model.profiles.count]) }
        }
    }

    /// The mark's opacity: the current space full, others clearly dimmer.
    static func markAlpha(active: Bool, hovered: Bool) -> CGFloat { active ? 1 : (hovered ? 0.9 : 0.7) }

    private func draw(profile: SidebarProfile, in rect: NSRect, active: Bool, hovered: Bool, compact: Bool) {
        let color = profileColor(profile, active: active).withAlphaComponent(Self.markAlpha(active: active, hovered: hovered))
        if compact {
            // Too many spaces for full marks: a small dot in the space's color.
            color.setFill()
            let diameter = min(Metrics.roomDotDiameter - 2, rect.width - 2)
            NSBezierPath(ovalIn: NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                                        width: diameter, height: diameter)).fill()
            return
        }
        if let icon = profile.icon, profile.iconIsEmoji {
            let font = NSFont.systemFont(ofSize: min(Metrics.smallIconSize + Metrics.space1, rect.height - Metrics.space2))
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = icon.size(withAttributes: attributes)
            // An emoji keeps its own colors, so its opacity is the context's.
            let context = NSGraphicsContext.current?.cgContext
            context?.saveGState()
            context?.setAlpha(color.alphaComponent)
            icon.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            context?.restoreGState()
            return
        }
        if let icon = profile.icon,
           let image = NSImage(systemSymbolName: icon, accessibilityDescription: profile.name)?.withSymbolConfiguration(
            // One weight for every state: a selection change never resizes a mark.
            NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize, weight: .regular)
           ) {
            let tinted = image.tinted(color.withAlphaComponent(1))
            let size = tinted.size
            tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                   width: size.width, height: size.height), from: .zero, operation: .sourceOver,
                        fraction: color.alphaComponent)
            return
        }
        if let initial = Self.initial(of: profile.name) {
            // No icon: the space's initial in its color (one weight for every
            // state, so a switch never resizes it).
            let font = NSFont.systemFont(ofSize: Metrics.smallIconSize - 1, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = initial.size(withAttributes: attributes)
            initial.draw(at: NSPoint(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded()),
                         withAttributes: attributes)
            return
        }
        color.setFill()
        let diameter = Metrics.roomDotDiameter
        NSBezierPath(ovalIn: NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                                    width: diameter, height: diameter)).fill()
    }

    /// The first letter of a space's name, uppercased; nil for an empty name.
    static func initial(of name: String) -> String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() }
    }

    /// The space's color, softened toward the strip a little so it sits in
    /// the sidebar chrome (less for the current space, so its color reads).
    // theme-scoped: called only from drawMarks(), inside performWithTheme
    private func profileColor(_ profile: SidebarProfile, active: Bool) -> NSColor {
        let base = profile.color?.swatch ?? Palette.textPrimary
        return base.blended(withFraction: active ? 0.05 : 0.2, of: Palette.stripStep) ?? base
    }

    // theme-scoped: called only from drawMarks() inside performWithTheme
    private func drawPlus(in rect: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize - Metrics.space3, weight: .regular)
        guard let image = NSImage(systemSymbolName: "plus", accessibilityDescription: Strings.newProfile)?.withSymbolConfiguration(config) else { return }
        // Tint opaque, then draw at the dot's alpha: a translucent tint over
        // the black template would stay nearly black.
        let color = Palette.textPrimary.withAlphaComponent(hovered == Self.plusIndex ? 0.6 : 0.35)
        let tinted = image.tinted(color.withAlphaComponent(1))
        let size = tinted.size
        tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: color.alphaComponent)
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
                if let new = layer.contents { _ = Motion.set(layer, "contents", to: new, fade: .crossfade, from: old) }
            }
        }
        needsDisplay = true
        marks.needsDisplay = true
        placeIndicator(animated: switched)
        rebuildToolTips()
        rebuildAccessibility()
    }

    private func rebuildToolTips() {
        removeAllToolTips()
        let rects = slotRects()
        for (offset, profile) in model.profiles.enumerated() {
            // The emoji is shown here, not on the dot.
            let tip = profile.iconIsEmoji ? [profile.icon, profile.name].compactMap(\.self).joined(separator: " ") : profile.name
            addToolTip(rects[offset], owner: tip as NSString, userData: nil)
        }
        if isPointerInside { addToolTip(rects[model.profiles.count], owner: Strings.newProfile as NSString, userData: nil) }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { setHovered(index(at: convert(event.locationInWindow, from: nil))) }
    override func mouseEntered(with event: NSEvent) { isPointerInside = true }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
        isPointerInside = false
    }

    /// The pointer entered or left (tests and the hover state of a drag).
    func setPointerInside(_ inside: Bool) { isPointerInside = inside }

    func setHovered(_ value: Int?) {
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
        setPressed(index(at: convert(event.locationInWindow, from: nil)))
    }

    // No drag: a dot cannot be dragged to reorder, and nothing drops on
    // the dots (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 3, for now). The
    // space menu's Move Left / Move Right reorder spaces.
    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            needsDisplay = true
        }
        guard let pressed, pressed == index(at: convert(event.locationInWindow, from: nil)) else { return }
        activate(pressed)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, let phase = Self.phase(of: event) else {
            super.scrollWheel(with: event)
            return
        }
        if let step = swipeTracker.feed(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY), phase: phase) {
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

    private func activate(_ index: Int) {
        if index == Self.plusIndex {
            model.send(.newProfile)
        } else if model.profiles.indices.contains(index), model.profiles[index].id != model.activeProfileID {
            model.send(.switchProfile(model.profiles[index].id))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = index(at: convert(event.locationInWindow, from: nil)), index != Self.plusIndex else { return nil }
        return contextMenuProvider?(.profile(model.profiles[index].id))
    }

    // MARK: Accessibility

    private func rebuildAccessibility() {
        let rects = slotRects()
        var children: [NSAccessibilityElement] = model.profiles.enumerated().map { offset, profile in
            let active = profile.id == model.activeProfileID
            let element = ProfileDotElement(label: active ? Strings.profileCurrent(profile.name) : profile.name,
                                            frame: rects[offset], parent: self) { [weak self] in self?.activate(offset) }
            element.setAccessibilitySelected(active)
            return element
        }
        children.append(ProfileDotElement(label: Strings.newProfile, frame: rects[model.profiles.count], parent: self) { [weak self] in
            self?.activate(Self.plusIndex)
        })
        setAccessibilityChildren(children)
    }
}

/// One pressable dot for VoiceOver.
private nonisolated final class ProfileDotElement: NSAccessibilityElement {
    private let onPress: @MainActor @Sendable () -> Void

    init(label: String, frame: NSRect, parent: Any, onPress: @escaping @MainActor @Sendable () -> Void) {
        self.onPress = onPress
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityParent(parent)
        setAccessibilityFrameInParentSpace(frame)
    }

    override func accessibilityPerformPress() -> Bool {
        // AppKit calls accessibility actions on the main thread.
        let onPress = onPress
        MainActor.assumeIsolated { onPress() }
        return true
    }
}

/// A non-interactive layer of the bar that draws through `onDraw`.
final class ProfileBarLayerView: NSView {
    var onDraw: ((NSRect) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { onDraw?(dirtyRect) }
}

extension NSImage {
    /// A copy drawn in `color` (symbol images are templates).
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
