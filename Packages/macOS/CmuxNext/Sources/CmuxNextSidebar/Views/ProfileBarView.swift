import AppKit
import CmuxNextDesign

/// The space switcher, leading at the bottom of the sidebar or under its
/// titlebar row (`sidebar.spacesPosition`, R109). Each profile keeps
/// its name, optional icon and tonal color in the shared daemon model. The
/// full-height slots remain easy to click, while the visible mark carries the
/// profile's identity without adding another layout document.
final class ProfileBarView: NSView {
    private let model: SidebarModel
    var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)?

    private var hovered: Int?
    private var pressed: Int?
    private var swipeTracker = ProfileSwipeTracker()
    private static let plusIndex = -1

    /// Called once for a qualifying horizontal trackpad swipe over the bar.
    var onHorizontalSwipe: ((Int) -> Void)?

    init(model: SidebarModel) {
        self.model = model
        super.init(frame: .zero)
        // Layer-backed so a selection change can crossfade its contents.
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Strings.profiles)
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
            rebuildToolTips()
        }
    }

    /// Where the first slot starts: the first dot sits on the rows' glyph
    /// column, over the profile avatar.
    static var leadingX: CGFloat { max(0, SidebarStyle.horizontalInset * 2 + SidebarStyle.iconBox / 2 - Metrics.roomDotSlot / 2) }
    /// Where this bar's first slot starts; nil uses `leadingX`. In the
    /// footer row the bar starts right after the profile control, so its
    /// dots follow the avatar (amendment 3).
    var leadingInset: CGFloat? { didSet { if leadingInset != oldValue { needsDisplay = true; rebuildToolTips() } } }
    var slotsLeading: CGFloat { leadingInset ?? Self.leadingX }

    /// Slot rects: one per room from the leading edge, then the "+" slot
    /// trailing the last dot (it never shifts the dots).
    private func slotRects() -> [NSRect] {
        ProfileBarLogic.slotXs(count: model.profiles.count, slot: slot, leading: slotsLeading).map {
            NSRect(x: $0, y: 0, width: slot, height: bounds.height)
        }
    }

    private func index(at point: NSPoint) -> Int? {
        let rects = slotRects()
        guard let hit = rects.firstIndex(where: { $0.contains(point) }) else { return nil }
        guard hit == model.profiles.count else { return hit }
        return isPointerInside ? Self.plusIndex : nil
    }

    // MARK: Drawing

    /// The dots drawn now: none for a lone space at rest (it switches nothing; the bar stays
    /// mounted so the chrome never shifts), every space otherwise.
    var drawnDotCount: Int {
        ProfileBarLogic.isVisible(profileCount: model.profiles.count) || isPointerInside ? model.profiles.count : 0
    }

    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            let rects = slotRects()
            if let chip = hoverChip {
                chip.fill.setFill()
                let radius = SidebarStyle.rowCornerRadius
                NSBezierPath(roundedRect: chip.rect, xRadius: radius, yRadius: radius).fill()
            }
            for (offset, profile) in model.profiles.enumerated().prefix(drawnDotCount) {
                let rect = rects[offset]
                let active = profile.id == model.activeProfileID
                draw(profile: profile, in: rect, active: active, hovered: hovered == offset)
            }
            if isPointerInside { drawPlus(in: rects[model.profiles.count]) }
        }
    }

    private func draw(profile: SidebarProfile, in rect: NSRect, active: Bool, hovered: Bool) {
        let alpha: CGFloat = active ? 0.82 : (hovered ? 0.62 : 0.38)
        let color = profileColor(profile).withAlphaComponent(alpha)
        if let icon = profile.icon, profile.iconIsEmoji {
            let font = NSFont.systemFont(ofSize: min(Metrics.smallIconSize + Metrics.space1, rect.height - Metrics.space2))
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = icon.size(withAttributes: attributes)
            icon.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
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
        color.setFill()
        let diameter = Metrics.roomDotDiameter
        NSBezierPath(ovalIn: NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                                    width: diameter, height: diameter)).fill()
    }

    /// Soften user colors with the strip tonal step so they sit naturally in
    /// the sidebar chrome.
    // theme-scoped: called only from draw(profile:in:active:hovered:), which
    // draw(_:) calls inside performWithTheme
    private func profileColor(_ profile: SidebarProfile) -> NSColor {
        let base = profile.color?.swatch ?? Palette.textPrimary
        return base.blended(withFraction: 0.45, of: Palette.stripStep) ?? base
    }

    // theme-scoped: called only from draw(_:) inside performWithTheme
    private func drawPlus(in rect: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize - Metrics.space3, weight: .regular)
        guard let image = NSImage(systemSymbolName: "plus", accessibilityDescription: Strings.newProfile)?.withSymbolConfiguration(config) else { return }
        // Tint opaque, then draw at the dot's alpha: a translucent tint over
        // the black template would stay nearly black.
        let color = Palette.textPrimary.withAlphaComponent(hovered == Self.plusIndex ? 0.48 : 0.28)
        let tinted = image.tinted(color.withAlphaComponent(1))
        let size = tinted.size
        tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: color.alphaComponent)
    }

    /// The space the bar last drew as active: a change crossfades.
    private var shownActive: ProfileKey?

    func refresh() {
        // A selection change only changes fill and opacity (Leo 2026-10-07:
        // no size or position jump): the slots are a pure function of the
        // count and width, and the new contents fade in briefly. Reduce
        // Motion snaps.
        if model.activeProfileID != shownActive {
            let wasShown = shownActive != nil
            shownActive = model.activeProfileID
            if wasShown, let layer, let old = layer.contents {
                display()
                if let new = layer.contents { _ = Motion.set(layer, "contents", to: new, fade: .crossfade, from: old) }
            }
        }
        needsDisplay = true
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
            return ProfileDotElement(label: active ? Strings.profileCurrent(profile.name) : profile.name,
                                     frame: rects[offset], parent: self) { [weak self] in self?.activate(offset) }
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
