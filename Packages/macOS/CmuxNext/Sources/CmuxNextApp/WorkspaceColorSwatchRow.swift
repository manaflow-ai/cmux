import AppKit
import CmuxNextActions
import CmuxNextDesign

/// The workspace menu's Color row (Leo 2026-10-11): the group colors as one row of swatches in
/// place of a Color submenu. A swatch runs its choice (Set Workspace Color with that color); the
/// current color is ringed, the hovered one ringed in the theme accent.
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
final class WorkspaceColorSwatchView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let choices: [NSMenuItem]
    private var swatches: [NSRect] = []
    private var hovered: Int?
    private static let diameter: CGFloat = 14, gap: CGFloat = 6, height: CGFloat = 28

    init(title: String, choices: [NSMenuItem]) {
        self.choices = choices
        let width = Metrics.space3 * 2 + 64 + CGFloat(choices.count) * (Self.diameter + Self.gap)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        label.stringValue = title
        label.font = .menuFont(ofSize: 0)
        label.textColor = .labelColor
        addSubview(label)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let size = label.fittingSize
        label.frame = NSRect(x: Metrics.space3 + 8, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        var x = bounds.width - Metrics.space3 - CGFloat(choices.count) * (Self.diameter + Self.gap) + Self.gap
        swatches = choices.map { _ in
            defer { x += Self.diameter + Self.gap }
            return NSRect(x: x, y: (bounds.height - Self.diameter) / 2, width: Self.diameter, height: Self.diameter)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, rect) in swatches.enumerated() {
            let color = ActionRegistry.menuRun(of: choices[index])?.arguments["color"]?.stringValue.flatMap(GroupColor.init(rawValue:))
            (color?.markColor ?? .systemGray).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let ringed = index == hovered ? Palette.accent : choices[index].state == .on ? NSColor.labelColor : nil
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
        let choice = choices[index]
        enclosingMenuItem?.menu?.cancelTracking()
        if let action = choice.action { NSApp.sendAction(action, to: choice.target, from: choice) }
    }
}
