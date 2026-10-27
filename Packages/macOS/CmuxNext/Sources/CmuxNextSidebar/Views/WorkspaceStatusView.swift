import AppKit
import CmuxNextDesign

/// The status block under a workspace row's name (`WorkspaceRowContent.status`):
/// one line per status entry (icon and text in the entry's color), "N more"
/// past the limit, the newest log line with its level glyph, then the
/// progress label. The row draws its progress bar in the slot this block
/// leaves before the label (`barSlotY`). Line pitch matches
/// `SidebarLayoutMetrics.statusHeight`.
final class WorkspaceStatusView: NSView {
    private static var pillHorizontalPadding: CGFloat { Metrics.space2 }
    private static let pillFillAlpha: CGFloat = 0.16

    private var labels: [NSTextField] = []
    private var pills: [NSView] = []
    private var status = SidebarWorkspaceStatus()
    private var reservesBar = false
    /// The font the text was last configured for (the lines' widths follow it).
    private var font = SidebarStyle.subtitleFont
    /// The next paint builds text of another shape (a new status or font): the pills lay out again after it.
    /// A paint for a theme change alone keeps every width, so it asks for no layout.
    private var textReshaped = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .onSetNeedsDisplay // updateLayer sets text and colors only
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }

    /// `reservesBar`: the row has a progress bar, drawn between the log line and the label.
    func configure(_ status: SidebarWorkspaceStatus, reservesBar: Bool) {
        guard status != self.status || reservesBar != self.reservesBar || font != SidebarStyle.subtitleFont else { return }
        textReshaped = textReshaped || status != self.status || font != SidebarStyle.subtitleFont
        self.status = status
        self.reservesBar = reservesBar
        font = SidebarStyle.subtitleFont
        while labels.count < status.lines.count {
            let pill = NSView()
            pill.wantsLayer = true
            pill.layer?.cornerCurve = .continuous
            pills.append(pill)
            addSubview(pill)

            let label = SidebarRowView.attributedLabel(font: SidebarStyle.subtitleFont)
            labels.append(label)
            addSubview(label)
        }
        for (index, label) in labels.enumerated() {
            let hidden = index >= status.lines.count
            label.isHidden = hidden
            pills[index].isHidden = hidden
        }
        // invalidate: the status, bar slot or font changed (the guard above).
        needsLayout = true; needsDisplay = true
    }

    /// Where the row's progress bar slot starts in this view: before the
    /// progress label, else after the last line.
    func barSlotY(_ metrics: SidebarLayoutMetrics) -> CGFloat {
        let index = status.lines.firstIndex { if case .progressLabel = $0 { true } else { false } } ?? status.lines.count
        return CGFloat(index) * metrics.statusLineHeight
    }

    override func updateLayer() {
        // Built here so palette colors resolve in the row's theme scope.
        performWithTheme {
            for (index, line) in status.lines.enumerated() where index < labels.count {
                labels[index].attributedStringValue = Self.text(for: line)
                Self.paint(pill: pills[index], for: line)
            }
        }
        // The pill width is content-sized: text of a new shape lays the pills out again once it is built.
        // invalidate: `configure` saw a new status or font.
        if textReshaped { needsLayout = true }
        textReshaped = false
    }

    override func layout() {
        super.layout()
        let metrics = SidebarLayoutMetrics.standard
        let lineHeight = metrics.statusLineHeight
        let labelHeight = max(lineHeight, ceil(SidebarStyle.subtitleFont.boundingRectForFont.height))
        var y: CGFloat = 0
        for (index, line) in status.lines.enumerated() {
            if case .progressLabel = line, reservesBar { y += metrics.progressBarHeight }
            let rowY = y - (labelHeight - lineHeight) / 2
            guard Self.isPill(line) else {
                pills[index].isHidden = true
                labels[index].frame = NSRect(x: 0, y: rowY, width: bounds.width, height: labelHeight)
                y += lineHeight
                continue
            }
            let width = Self.pillWidth(for: labels[index], maxWidth: bounds.width)
            // The text arrives in updateLayer(), after the first layout; an
            // empty pill would flash as a bare sliver until then.
            pills[index].isHidden = labels[index].attributedStringValue.length == 0
            pills[index].frame = NSRect(x: 0, y: rowY, width: width, height: labelHeight)
            labels[index].frame = NSRect(x: Self.pillHorizontalPadding, y: rowY,
                                         width: max(0, width - Self.pillHorizontalPadding * 2), height: labelHeight)
            y += lineHeight
        }
    }

    // MARK: Text

    // theme-scoped: called only from updateLayer(), inside performWithTheme
    private static func text(for line: SidebarWorkspaceStatus.Line) -> NSAttributedString {
        switch line {
        case .entry(let entry):
            let color = entry.tint.map(Self.color) ?? Palette.textSecondary
            return compose(icon: entry.icon, color: color, text: entry.displayText, textColor: color, image: entry.image)
        case .more(let count):
            return compose(icon: nil, color: Palette.textTertiary, text: Strings.statusMore(count), textColor: Palette.textTertiary)
        case .log(let log):
            return compose(icon: log.level.symbol, color: Self.color(log.level), text: log.text, textColor: Palette.textSecondary,
                           iconScale: 0.7)
        case .progressLabel(let label):
            return compose(icon: nil, color: Palette.textTertiary, text: label, textColor: Palette.textTertiary)
        }
    }

    private static func isPill(_ line: SidebarWorkspaceStatus.Line) -> Bool {
        if case .entry(let entry) = line { return entry.isActionable }
        return false
    }

    /// The cells own size includes the text fields inset, so the label fits
    /// its text without truncating it.
    private static func pillWidth(for label: NSTextField, maxWidth: CGFloat) -> CGFloat {
        let natural = label.cell?.cellSize.width ?? label.intrinsicContentSize.width
        return min(maxWidth, ceil(natural) + pillHorizontalPadding * 2)
    }

    // theme-scoped: called only from updateLayer(), inside performWithTheme
    private static func paint(pill: NSView, for line: SidebarWorkspaceStatus.Line) {
        guard case .entry(let entry) = line, entry.isActionable else {
            pill.layer?.backgroundColor = nil
            pill.layer?.cornerRadius = 0
            return
        }
        let color = entry.tint.map(Self.color) ?? Palette.textSecondary
        pill.layer?.backgroundColor = color.withAlphaComponent(pillFillAlpha).cgColor
        pill.layer?.cornerRadius = Metrics.chipCornerRadius(height: SidebarStyle.subtitleFont.boundingRectForFont.height)
    }

    /// `icon` is an SF Symbol name or one emoji; an unknown symbol name (or a stored asset not
    /// read yet) is left out rather than drawn as text. `image` is a stored asset's image.
    private static func compose(icon: String?, color: NSColor, text: String, textColor: NSColor,
                                iconScale: CGFloat = 0.85, image: SidebarFavicon? = nil) -> NSAttributedString {
        let font = SidebarStyle.subtitleFont
        let result = NSMutableAttributedString()
        if let image {
            let attachment = NSTextAttachment()
            let side = font.pointSize
            attachment.image = NSImage(cgImage: image.image, size: NSSize(width: side, height: side))
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " ", attributes: [.font: font]))
        } else if let icon, !icon.isEmpty {
            let config = NSImage.SymbolConfiguration(pointSize: font.pointSize * iconScale, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            if let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let attachment = NSTextAttachment()
                attachment.image = image
                let size = image.size
                attachment.bounds = CGRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: " ", attributes: [.font: font]))
            } else if !icon.unicodeScalars.allSatisfy({ $0.isASCII }) {
                result.append(NSAttributedString(string: icon + " ", attributes: [.font: font]))
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: textColor]))
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    static func color(_ tint: SidebarWorkspaceStatus.Tint) -> NSColor {
        switch tint {
        case .palette(let token): token.markColor
        case .rgba(let value):
            NSColor(srgbRed: CGFloat(value >> 24 & 0xFF) / 255, green: CGFloat(value >> 16 & 0xFF) / 255,
                    blue: CGFloat(value >> 8 & 0xFF) / 255, alpha: CGFloat(value & 0xFF) / 255)
        }
    }

    /// Level colors come from the theme's palette; no blue accent.
    // theme-scoped: called only from text(for:), inside updateLayer()'s performWithTheme
    private static func color(_ level: SidebarWorkspaceStatus.LogLevel) -> NSColor {
        switch level {
        case .info, .progress: Palette.textTertiary
        case .success: Palette.success
        case .warning: Palette.attention
        case .error: Palette.danger
        }
    }
}
