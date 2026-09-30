import AppKit
import CmuxNextDesign

/// A small drawing of each tour idea in the current theme's colors: the
/// palette, keys that reach cmux, rooms, splits, screens. Pure drawing.
final class TourIllustrationView: NSView {
    var kind: TourPage.Kind = .palette { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let unit = max(3, min(bounds.width / 60, bounds.height / 28))
        switch kind {
        case .palette: drawPalette(unit)
        case .keyTiers: drawKeys(unit)
        case .rooms: drawRooms(unit)
        case .splits: drawSplits(unit)
        case .screens: drawScreens(unit)
        }
    }

    // MARK: Pieces

    private func fill(_ rect: NSRect, _ color: NSColor, _ radius: CGFloat) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    private func stroke(_ rect: NSRect, _ color: NSColor, _ radius: CGFloat, width: CGFloat = 1) {
        color.setStroke()
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
        path.lineWidth = width
        path.stroke()
    }

    private func text(_ rect: NSRect, _ color: NSColor, unit: CGFloat) {
        fill(NSRect(x: rect.minX, y: rect.midY - unit * 0.3, width: rect.width, height: unit * 0.6), color, unit * 0.3)
    }

    /// A miniature window frame; returns its content rect.
    private func window(_ rect: NSRect, unit: CGFloat) -> NSRect {
        fill(rect, Palette.windowBackground, unit * 1.2)
        stroke(rect, Palette.separator, unit * 1.2)
        return rect.insetBy(dx: unit, dy: unit)
    }

    private var stage: NSRect { bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.08) }

    // MARK: Ideas

    private func drawPalette(_ unit: CGFloat) {
        let card = NSRect(x: stage.minX + stage.width * 0.1, y: stage.minY, width: stage.width * 0.8, height: stage.height)
        fill(card, Palette.elevatedBackground, unit * 1.5)
        stroke(card, Palette.separator, unit * 1.5)
        let search = NSRect(x: card.minX + unit * 2, y: card.minY + unit * 1.6, width: card.width * 0.45, height: unit * 2)
        text(search, Palette.textPrimary, unit: unit)
        fill(NSRect(x: card.minX, y: card.minY + unit * 4.6, width: card.width, height: 1), Palette.separator, 0)
        let rowHeight = (card.height - unit * 6.4) / 4
        for index in 0..<4 {
            let row = NSRect(x: card.minX + unit, y: card.minY + unit * 5.4 + CGFloat(index) * rowHeight, width: card.width - unit * 2, height: rowHeight - unit * 0.4)
            if index == 0 { fill(row, Palette.selectionFill, unit * 0.8) }
            fill(NSRect(x: row.minX + unit, y: row.midY - unit * 0.7, width: unit * 1.4, height: unit * 1.4), Palette.textTertiary, unit * 0.4)
            text(NSRect(x: row.minX + unit * 3.4, y: row.minY, width: row.width * (0.5 - CGFloat(index) * 0.06), height: row.height),
                 index == 0 ? Palette.textPrimary : Palette.textSecondary, unit: unit)
            text(NSRect(x: row.maxX - unit * 5, y: row.minY, width: unit * 4, height: row.height), Palette.textTertiary, unit: unit)
        }
    }

    private func drawKeys(_ unit: CGFloat) {
        let page = window(stage, unit: unit)
        for line in 0..<4 {
            text(NSRect(x: page.minX + unit, y: page.minY + unit * (1.5 + CGFloat(line) * 2), width: page.width * [0.7, 0.5, 0.62, 0.4][line], height: unit),
                 Palette.textTertiary, unit: unit)
        }
        let labels = ["⌘", "⌥", "←", "→"]
        let side = unit * 4.4
        let total = side * 4 + unit * 3
        for (index, label) in labels.enumerated() {
            let key = NSRect(x: stage.midX - total / 2 + CGFloat(index) * (side + unit), y: stage.maxY - side - unit * 2.5, width: side, height: side)
            fill(key, Palette.elevatedBackground, unit)
            stroke(key, Palette.textPrimary.faded(0.7), unit, width: 1.5)
            let font = NSFont.systemFont(ofSize: side * 0.42, weight: .medium)
            let string = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: Palette.textPrimary])
            let size = string.size()
            string.draw(at: NSPoint(x: key.midX - size.width / 2, y: key.midY - size.height / 2))
        }
    }

    private func drawRooms(_ unit: CGFloat) {
        let content = window(stage, unit: unit)
        let sidebar = NSRect(x: content.minX, y: content.minY, width: content.width * 0.3, height: content.height)
        for row in 0..<4 {
            let rect = NSRect(x: sidebar.minX, y: sidebar.minY + CGFloat(row) * unit * 2.6, width: sidebar.width - unit, height: unit * 2.2)
            if row == 0 { fill(rect, Palette.selectionFill, unit * 0.6) }
            text(rect.insetBy(dx: unit, dy: 0).divided(atDistance: rect.width * 0.55, from: .minXEdge).slice, Palette.textSecondary, unit: unit)
        }
        let colors = [Palette.textPrimary, Palette.attention, Palette.success]
        for (index, color) in colors.enumerated() {
            let radius = index == 0 ? unit * 0.9 : unit * 0.7
            let center = NSPoint(x: sidebar.midX + CGFloat(index - 1) * unit * 2.6, y: sidebar.maxY - unit * 1.4)
            fill(NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), index == 0 ? color : color.faded(0.6), radius)
        }
        let pane = NSRect(x: sidebar.maxX + unit, y: content.minY, width: content.maxX - sidebar.maxX - unit, height: content.height)
        fill(pane, Palette.hoverFill, unit * 0.8)
        for line in 0..<3 {
            text(NSRect(x: pane.minX + unit, y: pane.minY + unit * (1.5 + CGFloat(line) * 2), width: pane.width * [0.6, 0.4, 0.5][line], height: unit),
                 Palette.textTertiary, unit: unit)
        }
    }

    private func drawSplits(_ unit: CGFloat) {
        let content = window(stage, unit: unit)
        let gap = unit * 0.8
        let left = NSRect(x: content.minX, y: content.minY, width: content.width * 0.5 - gap / 2, height: content.height)
        let right = NSRect(x: left.maxX + gap, y: content.minY, width: content.maxX - left.maxX - gap, height: content.height)
        let top = NSRect(x: right.minX, y: right.minY, width: right.width, height: right.height / 2 - gap / 2)
        let bottom = NSRect(x: right.minX, y: top.maxY + gap, width: right.width, height: right.maxY - top.maxY - gap)
        for (index, pane) in [left, top, bottom].enumerated() {
            fill(pane, index == 0 ? Palette.selectionFill : Palette.hoverFill, unit * 0.8)
            if index == 0 { stroke(pane, Palette.textPrimary.faded(0.5), unit * 0.8) }
            text(NSRect(x: pane.minX + unit, y: pane.minY + unit * 1.5, width: pane.width * 0.5, height: unit), Palette.textTertiary, unit: unit)
        }
    }

    private func drawScreens(_ unit: CGFloat) {
        let card = NSRect(x: stage.minX + unit * 4, y: stage.minY + unit * 3.5, width: stage.width - unit * 8, height: stage.height - unit * 3.5)
        for depth in (0..<3).reversed() {
            let offset = CGFloat(depth) * unit * 1.4
            let rect = card.insetBy(dx: offset * 1.2, dy: 0).offsetBy(dx: 0, dy: -offset)
            let content = window(rect, unit: unit)
            guard depth == 0 else { continue }
            let half = NSRect(x: content.minX, y: content.minY, width: content.width / 2 - unit * 0.4, height: content.height)
            fill(half, Palette.hoverFill, unit * 0.8)
            fill(NSRect(x: half.maxX + unit * 0.8, y: content.minY, width: content.maxX - half.maxX - unit * 0.8, height: content.height), Palette.hoverFill, unit * 0.8)
        }
        let pill = unit * 3.2
        for index in 0..<3 {
            let rect = NSRect(x: stage.midX - pill * 1.5 - unit + CGFloat(index) * (pill + unit), y: stage.minY, width: pill, height: unit * 1.4)
            fill(rect, index == 0 ? Palette.textPrimary : Palette.selectionFill, unit * 0.7)
        }
    }
}
