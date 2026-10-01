import AppKit
import CmuxNextDesign
import QuartzCore

/// The status block under a workspace row's title: one line per status
/// entry (icon and text in the entry's color), "N more" past the limit, the
/// newest log line with its level glyph, then the progress bar and its
/// label (`SidebarWorkspaceStatus.lines`). Line pitch and bar height match
/// `SidebarLayoutMetrics.height(for:)`.
final class WorkspaceStatusView: NSView {
    private var labels: [NSTextField] = []
    private let track = CALayer()
    private let fill = CALayer()
    private var status = SidebarWorkspaceStatus()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for bar in [track, fill] {
            bar.cornerCurve = .continuous
            layer?.addSublayer(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// Height of the block for `status` (the row adds its title line).
    static func height(of status: SidebarWorkspaceStatus) -> CGFloat {
        let metrics = SidebarLayoutMetrics.standard
        return CGFloat(status.lines.count) * metrics.statusLineHeight + (status.showsProgressBar ? metrics.progressBarHeight : 0)
    }

    func configure(_ status: SidebarWorkspaceStatus) {
        self.status = status
        let lines = status.lines
        while labels.count < lines.count {
            let label = SidebarRowView.label(font: SidebarStyle.subtitleFont, color: Palette.textSecondary)
            labels.append(label)
            addSubview(label)
        }
        for (index, label) in labels.enumerated() {
            label.isHidden = index >= lines.count
            guard index < lines.count else { continue }
            label.attributedStringValue = Self.text(for: lines[index])
        }
        track.isHidden = !status.showsProgressBar
        fill.isHidden = !status.showsProgressBar
        needsLayout = true
        needsDisplay = true
    }

    override func updateLayer() {
        track.backgroundColor = resolvedCGColor(Palette.separator)
        fill.backgroundColor = resolvedCGColor(Palette.textSecondary)
    }

    override func layout() {
        super.layout()
        let metrics = SidebarLayoutMetrics.standard
        let lineHeight = metrics.statusLineHeight
        let lines = status.lines
        let labelHeight = max(lineHeight, ceil(SidebarStyle.subtitleFont.boundingRectForFont.height))
        var y: CGFloat = 0
        for (index, line) in lines.enumerated() {
            if case .progressLabel = line, status.showsProgressBar {
                layoutBar(y: y, height: metrics.progressBarHeight)
                y += metrics.progressBarHeight
            }
            labels[index].frame = NSRect(x: 0, y: y - (labelHeight - lineHeight) / 2, width: bounds.width, height: labelHeight)
            y += lineHeight
        }
        // A bar without a label sits last.
        if status.showsProgressBar, !lines.contains(where: { if case .progressLabel = $0 { true } else { false } }) {
            layoutBar(y: y, height: metrics.progressBarHeight)
        }
    }

    private func layoutBar(y: CGFloat, height: CGFloat) {
        let thickness = Metrics.space1 + Metrics.space1 / 2
        let frame = CGRect(x: 0, y: y + (height - thickness) / 2, width: bounds.width, height: thickness)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = frame
        track.cornerRadius = thickness / 2
        var filled = frame
        filled.size.width = frame.width * CGFloat(status.progress?.value ?? 0)
        fill.frame = filled
        fill.cornerRadius = thickness / 2
        CATransaction.commit()
    }

    // MARK: Text

    private static func text(for line: SidebarWorkspaceStatus.Line) -> NSAttributedString {
        switch line {
        case .entry(let entry):
            let color = entry.tint.map(Self.color) ?? Palette.textSecondary
            return compose(icon: entry.icon, color: color, text: entry.displayText, textColor: color)
        case .more(let count):
            return compose(icon: nil, color: Palette.textTertiary, text: Strings.statusMore(count), textColor: Palette.textTertiary)
        case .log(let log):
            return compose(icon: log.level.symbol, color: Self.color(log.level), text: log.text, textColor: Palette.textSecondary,
                           iconScale: 0.7)
        case .progressLabel(let label):
            return compose(icon: nil, color: Palette.textTertiary, text: label, textColor: Palette.textTertiary)
        }
    }

    /// `icon` is an SF Symbol name or one emoji; an unknown symbol name is
    /// left out rather than drawn as text.
    private static func compose(icon: String?, color: NSColor, text: String, textColor: NSColor,
                                iconScale: CGFloat = 0.85) -> NSAttributedString {
        let font = SidebarStyle.subtitleFont
        let result = NSMutableAttributedString()
        if let icon, !icon.isEmpty {
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
        case .palette(let token): token.swatch
        case .rgba(let value):
            NSColor(srgbRed: CGFloat(value >> 24 & 0xFF) / 255, green: CGFloat(value >> 16 & 0xFF) / 255,
                    blue: CGFloat(value >> 8 & 0xFF) / 255, alpha: CGFloat(value & 0xFF) / 255)
        }
    }

    /// Level colors come from the theme's ANSI palette; no blue accent.
    static func color(_ level: SidebarWorkspaceStatus.LogLevel) -> NSColor {
        switch level {
        case .info, .progress: Palette.textTertiary
        case .success: Palette.success
        case .warning: Palette.attention
        case .error: Palette.danger
        }
    }
}
