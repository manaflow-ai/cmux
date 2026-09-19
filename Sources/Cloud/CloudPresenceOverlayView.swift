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
    private var laserStartTimes: [UInt64: UInt64] = [:]

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
        let now = Self.now()
        let previousEntries = self.entries
        var nextLaserStartTimes: [UInt64: UInt64] = [:]
        for entry in entries {
            guard let highlight = entry.highlight, highlight.mode == .laser else { continue }
            if let previous = previousEntries.first(where: { $0.client == entry.client }),
               previous.highlight == entry.highlight,
               let start = laserStartTimes[entry.client] {
                nextLaserStartTimes[entry.client] = start
            } else {
                nextLaserStartTimes[entry.client] = min(entry.updatedAtMs, now)
            }
        }
        laserStartTimes = nextLaserStartTimes
        self.entries = entries
        isHidden = entries.isEmpty
        scheduleFadeIfNeeded()
    }

    /// Laser highlights and idle pointers age out on the viewer's clock, so
    /// keep redrawing while anything on screen can still expire.
    private func scheduleFadeIfNeeded() {
        fadeTimer?.cancel()
        fadeTimer = nil
        guard entries.contains(where: { entry in
            entry.highlight?.mode == .laser || entry.pointer != nil
        }) else { return }
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
            return highlight.mode == .pin || laserAge(of: entry, now: now) < Self.laserLifetime
        }
        return false
    }

    private func laserAge(of entry: CloudPresenceEntry, now: UInt64) -> TimeInterval {
        let start = laserStartTimes[entry.client] ?? entry.updatedAtMs
        guard now > start else { return 0 }
        return TimeInterval(now - start) / 1000
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard geometry.cellSize.width > 0, geometry.cellSize.height > 0,
              geometry.columns > 0, geometry.rows > 0 else { return }
        let now = Self.now()
        for entry in entries {
            let color = Self.palette[Int(entry.color & 7)]
            let age = age(of: entry, now: now)
            if let highlight = entry.highlight {
                let alpha: CGFloat
                switch highlight.mode {
                case .pin:
                    alpha = 0.28
                case .laser:
                    let highlightAge = laserAge(of: entry, now: now)
                    alpha = highlightAge < Self.laserLifetime
                        ? 0.34 * CGFloat(max(0, 1 - highlightAge / Self.laserLifetime))
                        : 0
                }
                if alpha > 0 {
                    drawHighlight(highlight, color: color.withAlphaComponent(alpha))
                }
            }
            if let pointer = entry.pointer, age < Self.pointerLifetime,
               let rect = cellRect(for: pointer) {
                drawPointer(
                    at: rect,
                    color: color,
                    label: entry.name ?? String(localized: "cloud.presence.client", defaultValue: "client")
                )
            }
        }
    }

    private func cellRect(for anchor: CloudPresenceAnchor) -> CGRect? {
        guard case let .cell(cell) = anchor,
              let row = anchor.viewerRow(viewerScrollOffset: geometry.scrollOffset, rows: geometry.rows),
              cell.col < UInt32(geometry.columns) else { return nil }
        let col = Int(cell.col)
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
        guard case let .cell(startCell) = highlight.start,
              case let .cell(endCell) = highlight.end,
              let startRow = highlight.start.shiftedRow(viewerScrollOffset: geometry.scrollOffset),
              let endRow = highlight.end.shiftedRow(viewerScrollOffset: geometry.scrollOffset) else { return }
        var first = (
            row: startRow,
            col: Int(startCell.col)
        )
        var last = (
            row: endRow,
            col: Int(endCell.col)
        )
        let shouldSwap = first.row > last.row || (first.row == last.row && first.col > last.col)
        if shouldSwap {
            swap(&first, &last)
        }
        color.setFill()
        let lowerRow = max(first.row, 0)
        let upperRow = min(last.row, Int64(geometry.rows - 1))
        guard lowerRow <= upperRow else { return }
        let rowRange = lowerRow...upperRow
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
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Use the exact Computer Use kite cursor, anchored at the target cell's
        // top-left corner. This keeps remote presence visually consistent with
        // the cursor users see when cmux Computer Use drives a surface.
        let tip = CGPoint(x: cell.minX, y: cell.minY)
        context.saveGState()
        context.translateBy(x: tip.x, y: tip.y)
        ComputerUseCursorArtwork.drawPointer(in: context)
        context.restoreGState()

        // Keep the teammate name beside the same cursor hotspot.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        var pill = CGRect(
            x: tip.x + 18,
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
