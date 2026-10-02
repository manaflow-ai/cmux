import AppKit
import CmuxNextDesign

/// The conversation list column: a flat, custom-drawn list (no table view)
/// on the window background. Rows show title, time, a one-line preview, the
/// owner ("This Mac only") and unread state. Selection and hover are the
/// theme's foreground at low alpha (no blue).
final class ConversationListView: NSView {
    var rows: [HomeConversationSummary] = [] { didSet { if rows != oldValue { needsDisplay = true } } }
    var selectedID: String? { didSet { if selectedID != oldValue { needsDisplay = true } } }
    var onSelect: ((String) -> Void)?
    var onCreate: (() -> Void)?
    private var hovered: Int?
    private var tracking: NSTrackingArea?
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // a resize changes only the height: keep the drawn rows pinned to the top, redraw when taller
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .topLeft
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        let grew = newSize.height > frame.height || newSize.width != frame.width
        super.setFrameSize(newSize)
        if grew { needsDisplay = true }
    }

    var headerHeight: CGFloat { Metrics.tabStripHeight }
    var rowHeight: CGFloat { ceil(Typography.bodyEmphasized.pointSize * 1.3 + Typography.caption.pointSize * 2.6) + Metrics.space4 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func rowIndex(at point: CGPoint) -> Int? {
        guard point.y >= headerHeight else { return nil }
        let index = Int((point.y - headerHeight) / rowHeight)
        return index < rows.count ? index : nil
    }

    private var createButtonRect: CGRect {
        let size = headerHeight - Metrics.space2 * 2
        return CGRect(x: bounds.width - Metrics.space4 - size, y: Metrics.space2, width: size, height: size)
    }

    override func mouseMoved(with event: NSEvent) {
        let next = rowIndex(at: convert(event.locationInWindow, from: nil))
        if next != hovered { hovered = next; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if createButtonRect.contains(point) { onCreate?(); return }
        if let index = rowIndex(at: point) { onSelect?(rows[index].id) }
    }

    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            Palette.sidebarBackground.setFill()
            bounds.fill()
            let header = HomeStrings.conversations as NSString
            header.draw(at: CGPoint(x: Metrics.space5, y: (headerHeight - Typography.header.pointSize * 1.3) / 2),
                        withAttributes: [.font: Typography.header, .foregroundColor: Palette.textSecondary])
            drawCreateButton()
            for (index, row) in rows.enumerated() {
                let frame = CGRect(x: Metrics.space2, y: headerHeight + CGFloat(index) * rowHeight,
                                   width: bounds.width - 2 * Metrics.space2, height: rowHeight)
                guard frame.intersects(dirtyRect) else { continue }
                drawRow(row, in: frame, selected: row.id == selectedID, hovered: index == hovered)
            }
        }
    }

    private func drawCreateButton() { // theme-scoped
        let rect = createButtonRect
        guard let image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: HomeStrings.newConversation)
        else { return }
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize, weight: .regular)
            .applying(.init(paletteColors: [Palette.textSecondary]))
        let symbol = image.withSymbolConfiguration(config) ?? image
        let size = symbol.size
        symbol.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
                               height: size.height))
    }

    private func drawRow(_ row: HomeConversationSummary, in frame: CGRect, selected: Bool, hovered: Bool) { // theme-scoped
        if selected || hovered {
            (selected ? Palette.selectionFill : Palette.hoverFill).setFill()
            NSBezierPath(roundedRect: frame, xRadius: Metrics.itemCornerRadius, yRadius: Metrics.itemCornerRadius).fill()
        }
        let inset = frame.insetBy(dx: Metrics.space4, dy: Metrics.space3)
        let unread = row.unreadCount > 0
        let titleFont = unread || selected ? Typography.bodyEmphasized : Typography.body
        let time = Calendar.current.isDateInToday(row.updatedAt)
            ? timeFormatter.string(from: row.updatedAt) : dayFormatter.string(from: row.updatedAt)
        let timeAttributes: [NSAttributedString.Key: Any] = [.font: Typography.caption, .foregroundColor: Palette.textTertiary]
        let timeWidth = ceil((time as NSString).size(withAttributes: timeAttributes).width)
        (time as NSString).draw(at: CGPoint(x: inset.maxX - timeWidth, y: inset.minY + 1), withAttributes: timeAttributes)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let titleRect = CGRect(x: inset.minX, y: inset.minY, width: inset.width - timeWidth - Metrics.space3,
                               height: ceil(titleFont.pointSize * 1.3))
        (row.title as NSString).draw(in: titleRect, withAttributes: [.font: titleFont, .foregroundColor: Palette.textPrimary,
                                                                   .paragraphStyle: paragraph])
        var y = titleRect.maxY + Metrics.space1
        let previewWidth = inset.width - (unread ? Metrics.space5 : 0)
        let preview = row.lastMessagePreview.replacingOccurrences(of: "\n", with: " ")
        (preview as NSString).draw(in: CGRect(x: inset.minX, y: y, width: previewWidth, height: ceil(Typography.caption.pointSize * 1.3)),
                                   withAttributes: [.font: Typography.caption, .foregroundColor: Palette.textSecondary,
                                                    .paragraphStyle: paragraph])
        y += ceil(Typography.caption.pointSize * 1.3)
        if let owner = row.ownerLabel {
            (owner as NSString).draw(at: CGPoint(x: inset.minX, y: y),
                                     withAttributes: [.font: Typography.caption, .foregroundColor: Palette.textTertiary])
        }
        if unread {
            let d = Metrics.space3
            Palette.textPrimary.setFill()
            NSBezierPath(ovalIn: CGRect(x: inset.maxX - d, y: titleRect.maxY + Metrics.space1 + 3, width: d, height: d)).fill()
        }
    }
}
