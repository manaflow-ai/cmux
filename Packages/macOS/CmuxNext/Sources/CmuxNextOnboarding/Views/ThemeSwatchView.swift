import AppKit
import CmuxNextDesign

/// A miniature cmux window drawn in one theme's colors: sidebar rows, a tab
/// strip and a few terminal lines in ANSI colors. Used for the theme cards
/// and, larger, for the live preview.
final class ThemeSwatchView: NSView {
    var input: ThemeInput { didSet { needsDisplay = true } }
    /// Draws the sidebar and tab strip (the large preview); cards show only terminal lines.
    var showsChrome: Bool

    init(input: ThemeInput, showsChrome: Bool) {
        self.input = input
        self.showsChrome = showsChrome
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let tokens = ThemeTokens.derive(from: input)
        tokens.windowBackground.withAlpha(1).nsColor.setFill()
        bounds.fill()
        var content = bounds
        let unit = max(2, bounds.height / 26)
        if showsChrome {
            let sidebar = NSRect(x: 0, y: 0, width: bounds.width * 0.26, height: bounds.height)
            content = NSRect(x: sidebar.maxX, y: 0, width: bounds.width - sidebar.width, height: bounds.height)
            drawSidebar(sidebar, tokens: tokens, unit: unit)
            let strip = NSRect(x: content.minX, y: unit * 2.5, width: content.width, height: unit * 3)
            drawTabs(strip, tokens: tokens, unit: unit)
            content = NSRect(x: content.minX, y: strip.maxY + unit, width: content.width, height: content.height - strip.maxY - unit)
        }
        drawTerminal(content.insetBy(dx: unit * 2, dy: unit * 1.5), tokens: tokens, unit: unit)
    }

    private func bar(_ rect: NSRect, _ color: NSColor, radius: CGFloat) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    private func drawSidebar(_ rect: NSRect, tokens: ThemeTokens, unit: CGFloat) {
        var y = unit * 3
        for index in 0..<5 {
            let row = NSRect(x: unit * 1.2, y: y, width: rect.width - unit * 2.4, height: unit * 2.4)
            if index == 1 { bar(row, tokens.selectionFill.nsColor, radius: unit * 0.6) }
            let text = NSRect(x: row.minX + unit, y: row.midY - unit * 0.35, width: row.width * (index == 1 ? 0.6 : 0.45), height: unit * 0.7)
            bar(text, (index == 1 ? tokens.textPrimary : tokens.textTertiary).nsColor, radius: unit * 0.35)
            y += unit * 3
        }
        tokens.separator.nsColor.setFill()
        NSRect(x: rect.maxX - 0.5, y: 0, width: 0.5, height: rect.height).fill()
    }

    private func drawTabs(_ rect: NSRect, tokens: ThemeTokens, unit: CGFloat) {
        let width = min(rect.width / 3.2, unit * 14)
        for index in 0..<3 {
            let tab = NSRect(x: rect.minX + unit + CGFloat(index) * (width + unit * 0.5), y: rect.minY, width: width, height: rect.height)
            if index == 0 { bar(tab, tokens.selectionFill.nsColor, radius: unit * 0.7) }
            let text = NSRect(x: tab.minX + unit, y: tab.midY - unit * 0.35, width: tab.width * 0.55, height: unit * 0.7)
            bar(text, (index == 0 ? tokens.textPrimary : tokens.textTertiary).nsColor, radius: unit * 0.35)
        }
    }

    private func drawTerminal(_ rect: NSRect, tokens: ThemeTokens, unit: CGFloat) {
        let ansi = tokens.ansi
        func color(_ index: Int) -> NSColor { (index < ansi.count ? ansi[index] : tokens.textPrimary).nsColor }
        // Each line: segments of (color, relative width); a prompt, output, a cursor.
        let lines: [[(NSColor, CGFloat)]] = [
            [(color(2), 0.06), (color(4), 0.16), (tokens.textPrimary.nsColor, 0.28)],
            [(tokens.textSecondary.nsColor, 0.42)],
            [(color(5), 0.12), (tokens.textSecondary.nsColor, 0.22), (color(3), 0.1)],
            [(color(1), 0.08), (tokens.textSecondary.nsColor, 0.34)],
            [(color(2), 0.06), (color(4), 0.16), (color(6), 0.2)],
        ]
        let step = max(unit * 1.8, rect.height / CGFloat(lines.count + 1))
        var y = rect.minY
        for line in lines {
            guard y + unit < rect.maxY else { break }
            var x = rect.minX
            for (segment, fraction) in line {
                let width = rect.width * fraction
                bar(NSRect(x: x, y: y, width: width, height: unit * 0.8), segment, radius: unit * 0.4)
                x += width + unit * 0.6
            }
            y += step
        }
        let cursor = NSRect(x: rect.minX, y: y, width: unit * 0.9, height: unit * 1.4)
        if cursor.maxY < rect.maxY { bar(cursor, tokens.textPrimary.nsColor, radius: 1) }
    }
}
