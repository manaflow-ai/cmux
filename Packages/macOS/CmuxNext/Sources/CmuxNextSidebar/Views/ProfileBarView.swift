import AppKit
import CmuxNextDesign

/// The room dots at the bottom center of the sidebar
/// (plans/cmux-next/data-model.md 7), deliberately plain (user: "more
/// minimal, muted, undesigned"): one small dot per room in the theme's
/// foreground at a low alpha, the current room a little stronger; no rings,
/// fills, colors, icons or labels (a room's emoji and name are in its
/// tooltip, its color and icon in its menu). Each dot's hit target is a
/// full-height slot. Click switches the window's room, right-click asks the
/// host for the room menu, dragging a dot reorders, and the trailing muted
/// "+" creates a room. Drawn in `draw(_:)` from the model's `profiles`.
final class ProfileBarView: NSView {
    private let model: SidebarModel
    var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)?

    private var hovered: Int?
    private var pressed: Int?
    private var drag: (index: Int, x: CGFloat)?
    private static let plusIndex = -1

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
                dotColor(active: active, hovered: hovered == offset).setFill()
                let diameter = Metrics.roomDotDiameter
                NSBezierPath(ovalIn: NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)).fill()
            }
            if isPointerInside { drawPlus(in: rects[model.profiles.count]) }
        }
    }

    /// Muted foreground: the current room a little stronger, a hovered one
    /// between. Never the room's color. theme-scoped: called only from draw(_:)
    private func dotColor(active: Bool, hovered: Bool) -> NSColor {
        Palette.textPrimary.withAlphaComponent(active ? 0.55 : (hovered ? 0.38 : 0.22))
    }

    // theme-scoped: called only from draw(_:) inside performWithTheme
    private func drawPlus(in rect: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize - Metrics.space3, weight: .regular)
        guard let image = NSImage(systemSymbolName: "plus", accessibilityDescription: Strings.newProfile)?.withSymbolConfiguration(config) else { return }
        // Tint opaque, then draw at the dot's alpha: a translucent tint over
        // the black template would stay nearly black.
        let color = dotColor(active: false, hovered: hovered == Self.plusIndex)
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
