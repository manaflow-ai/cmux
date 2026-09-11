import AppKit

/// Draws teammates' pointers and highlights above one cloud terminal pane.
///
/// Click-through and hit-test transparent, so it never steals input from the
/// Ghostty surface below. Geometry (cell size, grid, scroll offset) is fed by
/// the owning scroll view; the overlay only maps daemon anchors to rectangles.
final class CloudPresenceOverlayView: NSView {
    struct Geometry: Equatable {
        var cellSize: CGSize
        var columns: Int
        var rows: Int
        /// Rows this viewer's viewport sits above the live bottom.
        var scrollOffset: UInt64
        var contentInset: CGPoint
    }

    /// A laser highlight older than this is not drawn.
    static let laserLifetime: TimeInterval = 2.5
    /// A pointer that has not moved for this long is not drawn.
    static let pointerLifetime: TimeInterval = 4.0

    static let palette: [NSColor] = [
        NSColor(srgbRed: 0.98, green: 0.36, blue: 0.36, alpha: 1),
        NSColor(srgbRed: 0.26, green: 0.62, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.24, green: 0.80, blue: 0.48, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.70, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.72, green: 0.44, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.80, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.48, blue: 0.76, alpha: 1),
        NSColor(srgbRed: 0.64, green: 0.76, blue: 0.24, alpha: 1),
    ]

    var geometry = Geometry(cellSize: .zero, columns: 0, rows: 0, scrollOffset: 0, contentInset: .zero) {
        didSet { if geometry != oldValue { needsDisplay = true } }
    }

    private(set) var entries: [CloudPresenceEntry] = [] {
        didSet { if entries != oldValue { needsDisplay = true } }
    }

    private var fadeTimer: DispatchSourceTimer?

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        fadeTimer?.cancel()
    }

    func apply(entries: [CloudPresenceEntry]) {
        self.entries = entries
        isHidden = entries.isEmpty
        scheduleFadeIfNeeded()
    }

    /// Laser highlights and idle pointers age out on the viewer's clock, so
    /// keep redrawing while anything on screen can still expire.
    private func scheduleFadeIfNeeded() {
        fadeTimer?.cancel()
        fadeTimer = nil
        guard !entries.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.needsDisplay = true
            if !self.entries.contains(where: { self.isVisible($0, now: Self.now()) }) {
                self.fadeTimer?.cancel()
                self.fadeTimer = nil
            }
        }
        timer.resume()
        fadeTimer = timer
    }

    private static func now() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private func age(of entry: CloudPresenceEntry, now: UInt64) -> TimeInterval {
        guard now > entry.updatedAtMs else { return 0 }
        return TimeInterval(now - entry.updatedAtMs) / 1000
    }

    private func isVisible(_ entry: CloudPresenceEntry, now: UInt64) -> Bool {
        let age = age(of: entry, now: now)
        if entry.pointer != nil, age < Self.pointerLifetime { return true }
        if let highlight = entry.highlight {
            return highlight.mode == .pin || age < Self.laserLifetime
        }
        return false
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard geometry.cellSize.width > 0, geometry.cellSize.height > 0, geometry.rows > 0 else { return }
        let now = Self.now()
        for entry in entries {
            let color = Self.palette[entry.color & 7]
            let age = age(of: entry, now: now)
            if let highlight = entry.highlight {
                let alpha: CGFloat
                switch highlight.mode {
                case .pin:
                    alpha = 0.28
                case .laser:
                    alpha = age < Self.laserLifetime
                        ? 0.34 * CGFloat(max(0, 1 - age / Self.laserLifetime))
                        : 0
                }
                if alpha > 0 {
                    drawHighlight(highlight, color: color.withAlphaComponent(alpha))
                }
            }
            if let pointer = entry.pointer, age < Self.pointerLifetime,
               let rect = cellRect(for: pointer) {
                drawPointer(at: rect, color: color, label: entry.name ?? "client \(entry.client)")
            }
        }
    }

    private func cellRect(for anchor: CloudPresenceAnchor) -> CGRect? {
        guard case let .cell(_, col, _) = anchor,
              let row = anchor.viewerRow(viewerScrollOffset: geometry.scrollOffset, rows: geometry.rows),
              col >= 0, col < geometry.columns else { return nil }
        return CGRect(
            x: geometry.contentInset.x + CGFloat(col) * geometry.cellSize.width,
            y: geometry.contentInset.y + CGFloat(row) * geometry.cellSize.height,
            width: geometry.cellSize.width,
            height: geometry.cellSize.height
        )
    }

    /// A cell range is drawn like a text selection: partial first and last
    /// rows, full rows between. Rows off screen are skipped.
    private func drawHighlight(_ highlight: CloudPresenceHighlight, color: NSColor) {
        guard case let .cell(startRow, startCol, startOffset) = highlight.start,
              case let .cell(endRow, endCol, _) = highlight.end else { return }
        let shift = Int64(geometry.scrollOffset) - Int64(startOffset)
        var first = (row: Int64(startRow) + shift, col: startCol)
        var last = (row: Int64(endRow) + shift, col: endCol)
        if first.row > last.row || (first.row == last.row && first.col > last.col) {
            swap(&first, &last)
        }
        color.setFill()
        let rowRange = max(first.row, 0)...min(last.row, Int64(geometry.rows - 1))
        guard rowRange.lowerBound <= rowRange.upperBound else { return }
        for row in rowRange {
            let fromCol = row == first.row ? max(0, min(first.col, geometry.columns - 1)) : 0
            let toCol = row == last.row ? max(0, min(last.col, geometry.columns - 1)) : geometry.columns - 1
            guard fromCol <= toCol else { continue }
            let rect = CGRect(
                x: geometry.contentInset.x + CGFloat(fromCol) * geometry.cellSize.width,
                y: geometry.contentInset.y + CGFloat(row) * geometry.cellSize.height,
                width: CGFloat(toCol - fromCol + 1) * geometry.cellSize.width,
                height: geometry.cellSize.height
            )
            NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -0.5), xRadius: 2, yRadius: 2).fill()
        }
    }

    private func drawPointer(at cell: CGRect, color: NSColor, label: String) {
        // Cell frame.
        color.withAlphaComponent(0.9).setStroke()
        let frame = NSBezierPath(roundedRect: cell.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2)
        frame.lineWidth = 1.5
        frame.stroke()

        // Arrow cursor anchored at the cell's top-left corner.
        let tip = CGPoint(x: cell.minX, y: cell.minY)
        let arrow = NSBezierPath()
        arrow.move(to: tip)
        arrow.line(to: CGPoint(x: tip.x, y: tip.y + 13))
        arrow.line(to: CGPoint(x: tip.x + 3.5, y: tip.y + 10))
        arrow.line(to: CGPoint(x: tip.x + 6, y: tip.y + 15))
        arrow.line(to: CGPoint(x: tip.x + 8, y: tip.y + 14))
        arrow.line(to: CGPoint(x: tip.x + 5.5, y: tip.y + 9))
        arrow.line(to: CGPoint(x: tip.x + 10, y: tip.y + 9))
        arrow.close()
        color.setFill()
        arrow.fill()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        arrow.lineWidth = 1
        arrow.stroke()

        // Name pill beside the arrow.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        var pill = CGRect(
            x: tip.x + 12,
            y: tip.y + 12,
            width: size.width + 10,
            height: size.height + 4
        )
        if pill.maxX > bounds.maxX { pill.origin.x = max(0, bounds.maxX - pill.width) }
        if pill.maxY > bounds.maxY { pill.origin.y = max(0, tip.y - pill.height - 2) }
        color.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: CGPoint(x: pill.minX + 5, y: pill.minY + 2))
    }
}
