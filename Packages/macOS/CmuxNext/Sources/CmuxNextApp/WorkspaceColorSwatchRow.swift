import AppKit
import CmuxNextActions
import CmuxNextDesign

/// The workspace menu's Color row (Leo 2026-10-11): the group colors as one row of swatches in
/// place of a Color submenu. A swatch runs its choice (Set Workspace Color with that color); the
/// current color is ringed, the hovered one ringed in the theme accent. In a themed menu
/// (`NSMenu.themeRows(in:)`) the accent is the menu scope's. The title and the current ring are
/// `labelColor`, as `ThemedMenuRowView` inks the rows around it on AppKit's menu material.
@MainActor
enum WorkspaceColorSwatchRow {
    static let action: ActionID = "palette.workspaceColor"

    /// Swaps `menu`'s Set Workspace Color submenu for the swatch row. A menu without one is
    /// left as it is.
    static func inline(in menu: NSMenu) {
        guard let index = menu.items.firstIndex(where: { item in
            item.submenu?.items.contains { ActionRegistry.menuRun(of: $0)?.id == action } == true
        }), let submenu = menu.items[index].submenu else { return }
        let choices = submenu.items.filter { ActionRegistry.menuRun(of: $0)?.arguments["color"] != nil }
        guard !choices.isEmpty else { return }
        let title = menu.items[index].title
        let row = NSMenuItem()
        row.view = WorkspaceColorSwatchView(title: title, choices: choices)
        row.setAccessibilityLabel(title)
        menu.removeItem(at: index)
        menu.insertItem(row, at: index)
    }
}

/// One row: the row's title, then a swatch per choice.
final class WorkspaceColorSwatchView: NSView, ThemedMenuItemView {
    private let title: NSAttributedString
    private let choices: [NSMenuItem]
    private var swatches: [NSRect] = []
    private var hovered: Int?
    /// The scope of the view whose menu this is (`themeRows(in:)`); nil until a themed menu hands it.
    private var menuScope: ThemeScope?
    private static let diameter: CGFloat = 14, gap: CGFloat = 6, height: CGFloat = 28
    /// Where the menu's own item titles start and its shortcuts end, measured from captures of
    /// the shipped menu.
    private static let titleInset: CGFloat = 22, trailingInset: CGFloat = 13

    init(title: String, choices: [NSMenuItem]) {
        self.choices = choices
        // Drawn here rather than by a label field: a field turns vibrant inside the menu and
        // inks darker than the items around it.
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ])
        self.title = text
        // The title, a gap, then the swatches; the menu widens the row to its own width.
        let width = Self.titleInset + text.size().width + 16 + CGFloat(choices.count) * (Self.diameter + Self.gap) - Self.gap + Self.trailingInset
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        autoresizingMask = .width
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        // VoiceOver offers each color as an action of the row.
        setAccessibilityCustomActions(choices.indices.map { index in
            NSAccessibilityCustomAction(name: choices[index].title) { [weak self] in
                self?.run(index)
                return self != nil
            }
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func adoptMenuScope(_ scope: ThemeScope) {
        menuScope = scope
        needsDisplay = true
    }

    /// The hovered swatch's ring: the menu scope's accent.
    @objc var hoverRingColor: NSColor {
        if let menuScope { return menuScope.perform { Palette.accent } }
        return performWithTheme { Palette.accent }
    }

    /// A swatch whose color can't be read: the scope's tertiary ink, not the system gray.
    @objc var unknownSwatchColor: NSColor {
        if let menuScope { return menuScope.perform { Palette.textTertiary } }
        return performWithTheme { Palette.textTertiary }
    }

    override func layout() {
        super.layout()
        var x = bounds.width - Self.trailingInset - CGFloat(choices.count) * (Self.diameter + Self.gap) + Self.gap
        swatches = choices.map { _ in
            defer { x += Self.diameter + Self.gap }
            return NSRect(x: x, y: (bounds.height - Self.diameter) / 2, width: Self.diameter, height: Self.diameter)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = title.size()
        title.draw(at: NSPoint(x: Self.titleInset, y: ((bounds.height - size.height) / 2).rounded()))
        let hoverRing = hoverRingColor, unknown = unknownSwatchColor
        for (index, rect) in swatches.enumerated() {
            let color = ActionRegistry.menuRun(of: choices[index])?.arguments["color"]?.stringValue.flatMap(GroupColor.init(rawValue:))
            (color?.markColor ?? unknown).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let ringed = index == hovered ? hoverRing : choices[index].state == .on ? NSColor.labelColor : nil
            if let ringed {
                ringed.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
    }

    private func swatch(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return swatches.firstIndex { $0.insetBy(dx: -Self.gap / 2, dy: -4).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) { setHovered(swatch(at: event)) }
    override func mouseEntered(with event: NSEvent) { setHovered(swatch(at: event)) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    private func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = swatch(at: event) else { return }
        run(index)
    }

    private func run(_ index: Int) {
        let choice = choices[index]
        enclosingMenuItem?.menu?.cancelTracking()
        if let action = choice.action { NSApp.sendAction(action, to: choice.target, from: choice) }
    }
}
