import AppKit
import CmuxNextDesign

/// The profile dots at the bottom center of the sidebar (Arc spaces,
/// plans/cmux-next/data-model.md 7): one dot, or the profile's icon, per
/// profile with the current one emphasized. Click switches the window's
/// profile, right-click asks the host for the profile menu, dragging a dot
/// reorders, and the trailing "+" creates a profile. Low frequency chrome,
/// drawn in `draw(_:)` from the model's `profiles`.
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

    private var slot: CGFloat { Metrics.iconSize + Metrics.space3 }
    private var dotDiameter: CGFloat { Metrics.space3 }
    private var slotCount: Int { model.profiles.count + 1 }

    /// Slot rects, the "+" last, centered horizontally.
    private func slotRects() -> [NSRect] {
        let total = slot * CGFloat(slotCount)
        let x0 = (bounds.width - total) / 2
        let y = (bounds.height - slot) / 2
        return (0..<slotCount).map { NSRect(x: x0 + CGFloat($0) * slot, y: y, width: slot, height: slot) }
    }

    private func index(at point: NSPoint) -> Int? {
        let rects = slotRects()
        guard let hit = rects.firstIndex(where: { $0.contains(point) }) else { return nil }
        return hit == model.profiles.count ? Self.plusIndex : hit
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rects = slotRects()
        for (offset, profile) in model.profiles.enumerated() {
            var rect = rects[offset]
            if let drag, drag.index == offset { rect.origin.x = drag.x - rect.width / 2 }
            let active = profile.id == model.activeProfileID
            if hovered == offset || active {
                (active ? Palette.selectionFill : Palette.hoverFill).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: Metrics.itemCornerRadius, yRadius: Metrics.itemCornerRadius).fill()
            }
            draw(profile, in: rect, active: active)
        }
        drawPlus(in: rects[model.profiles.count])
    }

    private func tint(for profile: SidebarProfile, active: Bool) -> NSColor {
        if let color = profile.color { return active ? color.swatch : color.swatch.withAlphaComponent(0.7) }
        return active ? Palette.textPrimary : Palette.textTertiary
    }

    private func draw(_ profile: SidebarProfile, in rect: NSRect, active: Bool) {
        let color = tint(for: profile, active: active)
        if let icon = profile.icon {
            if profile.iconIsEmoji {
                let font = NSFont.systemFont(ofSize: Metrics.smallIconSize)
                let text = NSAttributedString(string: icon, attributes: [.font: font])
                let size = text.size()
                text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
                return
            }
            let config = NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize - Metrics.space1, weight: active ? .semibold : .regular)
            if let image = NSImage(systemSymbolName: icon, accessibilityDescription: profile.name)?.withSymbolConfiguration(config) {
                let tinted = image.tinted(color)
                let size = tinted.size
                tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
                return
            }
        }
        let diameter = active ? dotDiameter + Metrics.space1 : dotDiameter
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)).fill()
    }

    private func drawPlus(in rect: NSRect) {
        if hovered == Self.plusIndex {
            Palette.hoverFill.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: Metrics.itemCornerRadius, yRadius: Metrics.itemCornerRadius).fill()
        }
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize - Metrics.space2, weight: .semibold)
        guard let image = NSImage(systemSymbolName: "plus", accessibilityDescription: Strings.newProfile)?.withSymbolConfiguration(config) else { return }
        let tinted = image.tinted(Palette.textTertiary)
        let size = tinted.size
        tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    func refresh() {
        needsDisplay = true
        rebuildToolTips()
        rebuildAccessibility()
    }

    private func rebuildToolTips() {
        removeAllToolTips()
        let rects = slotRects()
        for (offset, profile) in model.profiles.enumerated() { addToolTip(rects[offset], owner: profile.name as NSString, userData: nil) }
        addToolTip(rects[model.profiles.count], owner: Strings.newProfile as NSString, userData: nil)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { setHovered(index(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

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
