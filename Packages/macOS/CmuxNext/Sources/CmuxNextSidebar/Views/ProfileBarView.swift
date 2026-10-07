import AppKit
import CmuxNextDesign

/// The space switcher, centered at the bottom of the sidebar or under its
/// titlebar row (`sidebar.spacesPosition`, R109). Each profile keeps
/// its name, optional icon and tonal color in the shared daemon model. The
/// full-height slots remain easy to click, while the visible mark carries the
/// profile's identity without adding another layout document.
final class ProfileBarView: NSView {
    private let model: SidebarModel
    var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)?

    private var hovered: Int?
    private var pressed: Int?
    private var drag: (index: Int, x: CGFloat)?
    private var swipeTracker = ProfileSwipeTracker()
    private static let plusIndex = -1

    /// Called once for a qualifying horizontal trackpad swipe over the bar.
    var onHorizontalSwipe: ((Int) -> Void)?

    init(model: SidebarModel) {
        self.model = model
        super.init(frame: .zero)
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
    /// and the dots stay centered without it).
    private(set) var isPointerInside = false {
        didSet {
            guard isPointerInside != oldValue else { return }
            needsDisplay = true
            rebuildToolTips()
        }
    }

    /// Slot rects: one per room, centered as a group, then the "+" slot
    /// trailing the last dot (it never shifts the dots).
    private func slotRects() -> [NSRect] {
        ProfileBarLogic.slotXs(count: model.profiles.count, slot: slot, width: bounds.width).map {
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

    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            let rects = slotRects()
            for (offset, profile) in model.profiles.enumerated() {
                var rect = rects[offset]
                if let drag, drag.index == offset { rect.origin.x = drag.x - rect.width / 2 }
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
            NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize, weight: active ? .medium : .regular)
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

    func refresh() {
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

    private func setHovered(_ value: Int?) {
        guard hovered != value else { return }
        hovered = value
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pressed = index(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, pressed != Self.plusIndex, model.profiles.count > 1 else { return }
        drag = (pressed, convert(event.locationInWindow, from: nil).x)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            drag = nil
            needsDisplay = true
        }
        if let drag {
            let rects = slotRects().prefix(model.profiles.count)
            let insertion = ProfileBarLogic.insertionIndex(forX: Double(drag.x), centers: rects.map { Double($0.midX) })
            let id = model.profiles[drag.index].id
            if ProfileBarLogic.finalIndex(from: drag.index, insertion: insertion, count: model.profiles.count) != nil {
                model.send(.reorderProfile(id, index: insertion))
            }
            return
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

private extension NSImage {
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
