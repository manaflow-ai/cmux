import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The shared notice card above the footer (BOTTOM-LEFT-CARDS K1; Lawrence
/// 2026-10-09): every message to the user in this slot (the "Did you know"
/// tip, the update status) is this card. An optional heading, an icon
/// beside the title (a small spinner while work has no measured progress),
/// one short detail of up to two lines, an optional progress bar, up to
/// two buttons (the call to action filled, the others quiet) with an
/// optional shortcut beside them, and an x. Rows a notice does not use take
/// no room. Hidden without a notice. It floats on Liquid Glass with the
/// theme's glass tint, like the other cmux-next overlays (cx-367y); under
/// Reduce Transparency the same `OverlaySurfaceView` draws an opaque theme
/// fill with a hairline.
final class SidebarNoticeCardView: NSView {
    /// A button: the notice's id and the action's id.
    var onAction: ((String, String) -> Void)?
    var onDismiss: ((String) -> Void)?
    private(set) var notice: SidebarNoticeCard?
    private let eyebrowLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    /// List lines under the detail (a changelog), one label each.
    private var lineLabels: [NSTextField] = []
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let track = CALayer()
    private let bar = CALayer()
    private(set) var actionButtons: [SidebarUpdateButton] = []
    let closeButton = SidebarIconButton(icon: .actionClose, pointSize: { 9 }, label: "")
    /// The card's material: Liquid Glass, or opaque under Reduce Transparency.
    let surface: OverlaySurfaceView
    /// The lines and buttons, flipped, over the surface.
    private let content = SidebarNoticeCardContent()

    init(frame: NSRect = .zero, reduceTransparency: ReduceTransparency = .shared) {
        surface = OverlaySurfaceView(interactive: true, cornerRadius: Metrics.space3, reduceTransparency: reduceTransparency)
        super.init(frame: frame)
        surface.translatesAutoresizingMaskIntoConstraints = true
        // The lines sit in a sibling view above the material, not inside the glass's own content
        // view: a build against the macOS 26 SDK drew the card empty on macOS 27 (nxdog75).
        addSubview(surface)
        addSubview(content)
        content.material = { [weak surface] in surface?.material ?? .liquidGlass }
        for label in [eyebrowLabel, titleLabel, shortcutLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.cell?.truncatesLastVisibleLine = true
        detailLabel.isSelectable = false
        shortcutLabel.alignment = .right
        icon.imageScaling = .scaleProportionallyDown
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        content.wantsLayer = true
        track.cornerRadius = 1.5
        bar.cornerRadius = 1.5
        content.layer?.addSublayer(track)
        content.layer?.addSublayer(bar)
        closeButton.onPress = { [weak self] in if let id = self?.notice?.id { self?.onDismiss?(id) } }
        [eyebrowLabel, titleLabel, detailLabel, shortcutLabel, icon, spinner, closeButton].forEach(content.addSubview)
        setAccessibilityElement(false)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Shows `notice`, or hides the view for nil.
    func configure(_ notice: SidebarNoticeCard?) {
        guard notice != self.notice else { return }
        let previous = self.notice
        self.notice = notice
        isHidden = notice == nil
        guard let notice else {
            spinner.stopAnimation(nil)
            return
        }
        eyebrowLabel.stringValue = notice.eyebrow ?? ""
        eyebrowLabel.isHidden = notice.eyebrow == nil
        titleLabel.stringValue = notice.title
        detailLabel.stringValue = notice.detail ?? ""
        detailLabel.isHidden = notice.detail == nil
        if previous?.lines != notice.lines {
            lineLabels.forEach { $0.removeFromSuperview() }
            lineLabels = notice.lines.prefix(Self.maxLines).map { line in
                let label = NSTextField(labelWithString: "• " + line)
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 1
                label.toolTip = line
                content.addSubview(label)
                return label
            }
        }
        shortcutLabel.stringValue = notice.shortcut ?? ""
        shortcutLabel.isHidden = notice.shortcut == nil || notice.actions.isEmpty
        let spins = notice.progress == .indeterminate
        icon.isHidden = notice.symbol == nil || spins
        spinner.isHidden = !spins
        if spins { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        closeButton.isHidden = notice.dismissLabel == nil
        closeButton.label = notice.dismissLabel ?? ""
        if previous?.actions != notice.actions { rebuildButtons(notice.actions) }
        let help = [notice.title, notice.detail].compactMap { $0 }.joined(separator: ". ")
        for (button, action) in zip(actionButtons, notice.actions) {
            button.configure(title: action.title, enabled: true, help: help)
        }
        needsLayout = true
        applyColors()
    }

    private func rebuildButtons(_ actions: [SidebarNoticeCard.Action]) {
        actionButtons.forEach { $0.removeFromSuperview() }
        actionButtons = actions.prefix(2).map { action in
            let button = SidebarUpdateButton()
            button.isQuiet = !action.prominent
            button.onPress = { [weak self] in
                guard let id = self?.notice?.id else { return }
                self?.onAction?(id, action.id)
            }
            content.addSubview(button)
            return button
        }
    }

    // MARK: Geometry

    private static var padding: CGFloat { Metrics.space3 }
    private static var lineHeight: (caption: CGFloat, body: CGFloat) {
        (ceil(Typography.caption.boundingRectForFont.height), ceil(Typography.bodyEmphasized.boundingRectForFont.height))
    }
    private static let barHeight: CGFloat = 3
    /// List lines a notice shows.
    static let maxLines = 4
    private static let closeSide: CGFloat = 16

    /// The card's height for `notice`: padding, the heading, the title, two
    /// detail lines, the progress bar and the button row when present.
    static func height(for notice: SidebarNoticeCard) -> CGFloat {
        let line = lineHeight
        var height = padding + line.body + padding
        if notice.eyebrow != nil { height += line.caption }
        if notice.detail != nil { height += Metrics.space1 + 2 * line.caption }
        if !notice.lines.isEmpty { height += Metrics.space1 + CGFloat(min(notice.lines.count, maxLines)) * line.caption }
        if case .fraction = notice.progress { height += Metrics.space2 + barHeight }
        if !notice.actions.isEmpty { height += Metrics.space2 + SidebarUpdateButton.height }
        return ceil(height)
    }

    override func layout() {
        super.layout()
        let b = bounds, pad = Self.padding, line = Self.lineHeight, close = Self.closeSide
        surface.frame = b
        surface.cornerRadius = Metrics.space3
        content.layer?.cornerRadius = Metrics.space3
        content.layer?.cornerCurve = .continuous
        content.frame = b
        eyebrowLabel.font = Typography.caption
        titleLabel.font = Typography.bodyEmphasized
        detailLabel.font = Typography.caption
        shortcutLabel.font = Typography.caption
        closeButton.frame = NSRect(x: b.width - pad / 2 - close, y: pad / 2, width: close, height: close)
        let width = max(0, b.width - 2 * pad), closeRoom = closeButton.isHidden ? 0 : close
        var y = pad
        if !eyebrowLabel.isHidden {
            eyebrowLabel.frame = NSRect(x: pad, y: y, width: max(0, width - closeRoom), height: line.caption)
            y += line.caption
        }
        let showsGlyph = !icon.isHidden || !spinner.isHidden
        let glyphSide = line.body, textX = pad + (showsGlyph ? glyphSide + Metrics.space2 : 0)
        icon.frame = NSRect(x: pad, y: y, width: glyphSide, height: glyphSide)
        spinner.frame = icon.frame
        let titleWidth = max(0, b.width - pad - textX - (eyebrowLabel.isHidden ? closeRoom : 0))
        titleLabel.frame = NSRect(x: textX, y: y, width: titleWidth, height: line.body)
        y += line.body
        let textWidth = max(0, b.width - pad - textX)
        if !detailLabel.isHidden {
            detailLabel.preferredMaxLayoutWidth = textWidth
            detailLabel.frame = NSRect(x: textX, y: y + Metrics.space1, width: textWidth, height: 2 * line.caption)
            y += Metrics.space1 + 2 * line.caption
        }
        if !lineLabels.isEmpty { y += Metrics.space1 }
        for label in lineLabels {
            label.font = Typography.caption
            label.frame = NSRect(x: textX, y: y, width: textWidth, height: line.caption)
            y += line.caption
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if case .fraction(let progress) = notice?.progress {
            y += Metrics.space2
            track.isHidden = false
            bar.isHidden = false
            track.frame = CGRect(x: textX, y: y, width: textWidth, height: Self.barHeight)
            bar.frame = CGRect(x: textX, y: y, width: textWidth * CGFloat(min(1, max(0.03, progress))), height: Self.barHeight)
        } else {
            track.isHidden = true
            bar.isHidden = true
        }
        CATransaction.commit()
        let rowY = b.height - pad - SidebarUpdateButton.height
        var x = pad
        for button in actionButtons {
            let titleWidth = ceil((button.title as NSString).size(withAttributes: [.font: SidebarUpdateButton.font]).width)
            let buttonWidth = min(max(0, b.width - pad - x), titleWidth + 2 * Metrics.space4)
            button.frame = NSRect(x: x, y: rowY, width: buttonWidth, height: SidebarUpdateButton.height)
            x = button.frame.maxX + Metrics.space2
        }
        shortcutLabel.frame = NSRect(x: x, y: rowY + (SidebarUpdateButton.height - line.caption) / 2,
                                     width: max(0, b.width - pad - x), height: line.caption)
    }

    private func applyColors() {
        performWithTheme {
            eyebrowLabel.textColor = Palette.textSecondary
            titleLabel.textColor = Palette.textPrimary
            detailLabel.textColor = Palette.textSecondary
            for label in lineLabels { label.textColor = Palette.textSecondary }
            shortcutLabel.textColor = Palette.textTertiary
            icon.contentTintColor = Palette.textSecondary
            icon.image = notice?.symbol.map { NSImage.icon(symbol: $0, size: .iconRowSize(forLabelPointSize: Typography.bodyEmphasized.pointSize)) }
            track.backgroundColor = Palette.hoverFill.cgColor
            bar.backgroundColor = Palette.textSecondary.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        surface.applyTheme()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    // MARK: Tests

    /// The text lines shown (heading, title, detail, shortcut).
    var lineViews: [NSView] { [eyebrowLabel, titleLabel, detailLabel, shortcutLabel].filter { !$0.isHidden } }

    /// Whether the icon (or the spinner) shows beside the title.
    var showsSymbol: Bool { !icon.isHidden || !spinner.isHidden }

    /// Every line as shown, top to bottom.
    var shownText: [String] {
        [eyebrowLabel, titleLabel, detailLabel].filter { !$0.isHidden }.map(\.stringValue) + actionButtons.map(\.title)
            + (shortcutLabel.isHidden ? [] : [shortcutLabel.stringValue])
    }
}

/// The notice card's lines, flipped, over the glass: a light theme veil
/// keeps them legible over a bright backdrop image; the opaque fill needs none.
private final class SidebarNoticeCardContent: NSView {
    /// The card's material (the surface beneath); the veil is for glass only.
    var material: () -> OverlayMaterial = { .liquidGlass }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = material() == .opaque
                ? NSColor.clear.cgColor
                : Palette.elevatedBackground.withAlphaComponent(0.32).cgColor
        }
    }
}
