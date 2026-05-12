import AppKit

struct TerminalRegexHighlightOverlayMetrics: Equatable {
    var cellSize: CGSize = .zero
    var rowCount: Int = 0
    var columnCount: Int = 0
    var xInset: CGFloat = 0
    var yInset: CGFloat = 0
}

final class TerminalRegexHighlightOverlayView: NSView {
    private var runs: [TerminalRegexHighlightRun] = []
    private var metrics = TerminalRegexHighlightOverlayMetrics()

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func configure(
        runs: [TerminalRegexHighlightRun],
        metrics: TerminalRegexHighlightOverlayMetrics
    ) {
        guard self.runs != runs || self.metrics != metrics || isHidden != runs.isEmpty else {
            return
        }
        self.runs = runs
        self.metrics = metrics
        isHidden = runs.isEmpty
        needsDisplay = true
    }

    func clear() {
        configure(runs: [], metrics: metrics)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !runs.isEmpty,
              metrics.cellSize.width > 0,
              metrics.cellSize.height > 0,
              metrics.rowCount > 0,
              metrics.columnCount > 0 else {
            return
        }

        for run in runs {
            guard run.row >= 0,
                  run.row < metrics.rowCount,
                  run.column >= 0,
                  run.column < metrics.columnCount,
                  run.length > 0 else {
                continue
            }

            let length = min(run.length, metrics.columnCount - run.column)
            guard length > 0 else { continue }

            let rect = CGRect(
                x: metrics.xInset + CGFloat(run.column) * metrics.cellSize.width,
                y: metrics.yInset + CGFloat(run.row) * metrics.cellSize.height,
                width: CGFloat(length) * metrics.cellSize.width,
                height: metrics.cellSize.height
            ).insetBy(dx: 1, dy: 1)

            TerminalRegexHighlightOverlayView.color(for: run.backgroundHex).setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: min(3, rect.height / 3),
                yRadius: min(3, rect.height / 3)
            ).fill()
        }
    }

    private static func color(for hex: String) -> NSColor {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard raw.count == 6 || raw.count == 8,
              let value = UInt64(raw, radix: 16) else {
            return NSColor.systemYellow.withAlphaComponent(0.5)
        }

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        if raw.count == 8 {
            red = CGFloat((value >> 24) & 0xFF) / 255
            green = CGFloat((value >> 16) & 0xFF) / 255
            blue = CGFloat((value >> 8) & 0xFF) / 255
            alpha = CGFloat(value & 0xFF) / 255
        } else {
            red = CGFloat((value >> 16) & 0xFF) / 255
            green = CGFloat((value >> 8) & 0xFF) / 255
            blue = CGFloat(value & 0xFF) / 255
            alpha = 0.5
        }

        return NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}
