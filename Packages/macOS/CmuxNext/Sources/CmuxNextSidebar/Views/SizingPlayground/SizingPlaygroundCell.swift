import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens

/// One specimen of the sizing playground: a tab strip, sidebar rows, the update card and its What's
/// New popover, all drawn from the tokens of one `sidebar.density` and `sidebar.textSize`
/// (``SidebarRowTokens``), side by side so a mismatch shows at a glance. With ``before`` the popover
/// draws the sizes it had before the derived system: the pages' 13 px type and 340 px width, zoomed
/// by the content scale (`app.uiScale`).
final class SizingPlaygroundCell: NSView {
    let tokens: SidebarRowTokens
    let before: Bool
    /// The page zoom the "before" popover was drawn under (`app.uiScale`).
    let zoom: CGFloat

    private static let sidebarWidth: CGFloat = 240
    private static let gutter: CGFloat = 24

    init(tokens: SidebarRowTokens, before: Bool, zoom: CGFloat) {
        self.tokens = tokens
        self.before = before
        self.zoom = zoom
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The popover's sizes this cell draws: derived, or the earlier page type under the zoom.
    var popover: SidebarPopoverMetrics {
        guard before else { return tokens.popover }
        let z = zoom
        return SidebarPopoverMetrics(width: 340, paddingX: 12 * z, paddingY: 10 * z, bodySize: 13 * z, bodyLine: 18 * z,
                                     detailSize: 12 * z, detailLine: 16 * z, itemPaddingY: 4 * z, numberColumn: 12 * z,
                                     columnGap: 6 * z, blockGap: 6 * z, mediaRadius: 6 * z)
    }

    /// The caption over the specimen: its settings and the numbers that matter.
    var caption: String {
        let pop = popover
        return "sidebar.density \(tokens.density.rawValue) · sidebar.textSize \(tokens.textSize.rawValue)  —  "
            + Strings.sizingCaption(row: Self.num(tokens.rowHeight), title: Self.num(tokens.titleSize), detail: Self.num(tokens.captionSize),
                                    width: Self.num(pop.width), body: Self.num(pop.bodySize), line: Self.num(pop.bodyLine))
    }

    private static func num(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", Double(value))
    }

    override var intrinsicContentSize: NSSize {
        let sidebar = tabStripHeight + 4 * tokens.rowHeight + tokens.base.space4 + cardHeight
        return NSSize(width: Self.sidebarWidth + Self.gutter + popover.width, height: max(sidebar, popoverHeight))
    }

    private var tabStripHeight: CGFloat { Metrics.tabHeight + 2 * tokens.base.space2 }

    private var cardHeight: CGFloat {
        let card = tokens.card
        return 2 * card.paddingY + SidebarPopoverMetrics.line(for: card.titleSize)
            + card.gap + SidebarPopoverMetrics.line(for: card.noteSize) + 2 * card.gap + card.buttonHeight
    }

    private var popoverHeight: CGFloat {
        let pop = popover
        let items = 3 * (2 * pop.itemPaddingY + 2 * pop.bodyLine + pop.detailLine)
        return 2 * pop.paddingY + 2 * pop.detailLine + pop.blockGap + items + 2 * pop.blockGap + pop.detailLine
    }

    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            var y: CGFloat = 0
            y = drawTabs(at: y)
            y = drawRows(at: y)
            drawCard(at: y + tokens.base.space4)
            drawPopover(x: Self.sidebarWidth + Self.gutter)
        }
    }

    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        Typography.system(.default, size: size, weight: weight)
    }

    /// `text` in one line `line` tall at `point`, cut at `width`.
    private func text(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
                      at point: CGPoint, line: CGFloat, width: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let fontValue = font(size, weight)
        let attributes: [NSAttributedString.Key: Any] = [.font: fontValue, .foregroundColor: color, .paragraphStyle: style]
        let height = ceil(fontValue.ascender - fontValue.descender)
        let rect = NSRect(x: point.x, y: point.y + (line - height) / 2, width: max(0, width), height: height)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    /// Three tab pills at the app density's tab height and body text (they follow `appearance.density`,
    /// not the sidebar's: the playground shows whether the two agree).
    private func drawTabs(at y: CGFloat) -> CGFloat {
        let height = Metrics.tabHeight
        let pill = (Self.sidebarWidth - 2 * tokens.base.space2) / 3
        for index in 0..<3 {
            let rect = NSRect(x: CGFloat(index) * pill + tokens.base.space1, y: y + tokens.base.space2, width: pill - tokens.base.space2, height: height)
            if index == 0 {
                Palette.selectionFill.setFill()
                NSBezierPath(roundedRect: rect, xRadius: tokens.base.cornerRadius, yRadius: tokens.base.cornerRadius).fill()
            }
            text(Strings.sizingTab(index + 1), size: Typography.body.pointSize, color: index == 0 ? Palette.textPrimary : Palette.textSecondary,
                 at: CGPoint(x: rect.minX + tokens.horizontalInset, y: rect.minY), line: height, width: rect.width - 2 * tokens.horizontalInset)
        }
        return y + tabStripHeight
    }

    /// Four workspace rows: the second selected (the rows' corner), the third with an unread dot.
    private func drawRows(at top: CGFloat) -> CGFloat {
        var y = top
        let inset = tokens.horizontalInset
        for index in 0..<4 {
            let row = NSRect(x: inset, y: y, width: Self.sidebarWidth - 2 * inset, height: tokens.rowHeight)
            if index == 1 {
                Palette.selectionFill.setFill()
                NSBezierPath(roundedRect: row, xRadius: tokens.base.cornerRadius, yRadius: tokens.base.cornerRadius).fill()
            }
            text(Strings.sizingWorkspace(index + 1), size: tokens.titleSize, color: Palette.textPrimary,
                 at: CGPoint(x: row.minX + inset, y: row.minY), line: row.height, width: row.width - 3 * inset)
            if index == 2 {
                let dot = (tokens.titleSize / 2).rounded()
                Palette.accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: row.maxX - inset - dot, y: row.midY - dot / 2, width: dot, height: dot)).fill()
            }
            y += tokens.rowHeight
        }
        return y
    }

    /// The Update Ready card at ``SidebarRowTokens/card``.
    private func drawCard(at top: CGFloat) {
        let card = tokens.card
        let inset = tokens.horizontalInset
        let box = NSRect(x: inset, y: top, width: Self.sidebarWidth - 2 * inset, height: cardHeight)
        Palette.hoverFill.setFill()
        NSBezierPath(roundedRect: box, xRadius: card.cornerRadius, yRadius: card.cornerRadius).fill()
        var y = box.minY + card.paddingY
        let width = box.width - 2 * card.paddingX
        let titleLine = SidebarPopoverMetrics.line(for: card.titleSize)
        text(Strings.sizingUpdateReady, size: card.titleSize, weight: .semibold, color: Palette.textPrimary,
             at: CGPoint(x: box.minX + card.paddingX, y: y), line: titleLine, width: width)
        y += titleLine + card.gap
        let noteLine = SidebarPopoverMetrics.line(for: card.noteSize)
        text(Strings.sizingUpdateNote, size: card.noteSize, color: Palette.textSecondary,
             at: CGPoint(x: box.minX + card.paddingX, y: y), line: noteLine, width: width)
        y += noteLine + 2 * card.gap
        let button = NSRect(x: box.minX + card.paddingX, y: y, width: width, height: card.buttonHeight)
        Palette.selectionFill.setFill()
        NSBezierPath(roundedRect: button, xRadius: card.buttonRadius, yRadius: card.buttonRadius).fill()
        let label = Strings.sizingRestart
        let labelWidth = (label as NSString).size(withAttributes: [.font: font(card.noteSize, .medium)]).width
        text(label, size: card.noteSize, weight: .medium, color: Palette.textPrimary,
             at: CGPoint(x: button.midX - labelWidth / 2, y: button.minY), line: button.height, width: labelWidth + 1)
    }

    /// The What's New popover at ``popover``, its top aligned with the card's row block.
    private func drawPopover(x: CGFloat) {
        let pop = popover
        let box = NSRect(x: x, y: 0, width: pop.width, height: popoverHeight)
        Palette.hoverFill.setFill()
        let radius = tokens.card.cornerRadius
        NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
        Palette.separator.setStroke()
        NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius).stroke()
        let left = box.minX + pop.paddingX
        let width = box.width - 2 * pop.paddingX
        var y = box.minY + pop.paddingY
        text(Strings.sizingWhatsNew, size: pop.detailSize, color: Palette.textSecondary, at: CGPoint(x: left, y: y), line: pop.detailLine, width: width)
        y += pop.detailLine
        text(Strings.sizingUpdateNote, size: pop.detailSize, color: Palette.textTertiary, at: CGPoint(x: left, y: y), line: pop.detailLine, width: width)
        y += pop.detailLine + pop.blockGap
        let textLeft = left + pop.numberColumn + pop.columnGap
        let textWidth = width - pop.numberColumn - pop.columnGap
        for index in 0..<3 {
            y += pop.itemPaddingY
            text("\(index + 1)", size: pop.detailSize, color: Palette.textTertiary, at: CGPoint(x: left, y: y), line: pop.bodyLine, width: pop.numberColumn)
            let words = Strings.sizingChange.split(separator: " ")
            let half = words.count / 2
            text(words[..<half].joined(separator: " "), size: pop.bodySize, color: Palette.textPrimary,
                 at: CGPoint(x: textLeft, y: y), line: pop.bodyLine, width: textWidth)
            y += pop.bodyLine
            text(words[half...].joined(separator: " "), size: pop.bodySize, color: Palette.textPrimary,
                 at: CGPoint(x: textLeft, y: y), line: pop.bodyLine, width: textWidth)
            y += pop.bodyLine
            text(Strings.sizingChangeDetail, size: pop.detailSize, color: Palette.textSecondary,
                 at: CGPoint(x: textLeft, y: y), line: pop.detailLine, width: textWidth)
            y += pop.detailLine + pop.itemPaddingY
        }
        y += pop.blockGap
        Palette.separator.setFill()
        NSRect(x: left, y: y, width: width, height: 1).fill()
        y += pop.blockGap
        let seeAll = Strings.sizingSeeAll
        let seeWidth = (seeAll as NSString).size(withAttributes: [.font: font(pop.detailSize, .medium)]).width
        text(seeAll, size: pop.detailSize, weight: .medium, color: Palette.textPrimary,
             at: CGPoint(x: box.maxX - pop.paddingX - seeWidth, y: y), line: pop.detailLine, width: seeWidth + 1)
    }
}
