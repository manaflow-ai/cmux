import AppKit
import CmuxNextDesign
import QuartzCore

/// A group chip drawn with CALayers: a muted color pill with the group name
/// (or a dot when unnamed) and, when collapsed, the member count. Used by
/// the strip and the saved groups bar.
final class TabGroupChipCell {
    let layer = CALayer()
    let accessibility = TabAccessibilityElement()

    private(set) var group: TabGroupItem
    private(set) var memberCount: Int
    /// Show the count even when expanded (saved groups bar).
    var alwaysShowsCount = false { didSet { if oldValue != alwaysShowsCount { contentChanged() } } }
    var isHovered = false { didSet { if oldValue != isHovered { updateColors(animated: true) } } }
    var isPressed = false { didSet { if oldValue != isPressed { updateColors(animated: false) } } }
    var isLifted = false {
        didSet {
            guard oldValue != isLifted else { return }
            pill.shadowColor = Palette.shadow.cgColor
            pill.shadowRadius = Metrics.space3
            pill.shadowOffset = CGSize(width: 0, height: Metrics.space1)
            pill.shadowOpacity = isLifted ? 0.22 : 0
            layer.zPosition = isLifted ? 11 : 1
        }
    }
    var metrics = TabStripMetrics.standard { didSet { if oldValue != metrics { contentChanged() } } }
    var font = Typography.caption { didSet { if oldValue != font { contentChanged() } } }
    var appearance = NSAppearance.currentDrawing() { didSet { if oldValue !== appearance { updateColors(animated: false) } } }
    /// Backing scale of the host window. Starts at 1 to match a new layer's
    /// `contentsScale`, so the first real assignment always reaches the layers.
    var scale: CGFloat = 1 {
        didSet {
            guard oldValue != scale else { return }
            nameLayer.contentsScale = scale
            countLayer.contentsScale = scale
        }
    }

    private let pill = CALayer()
    private let nameLayer = ChromeTextLayer()
    private let nameMask = CAGradientLayer()
    private let countLayer = ChromeTextLayer()
    private var measured: (name: String, count: String, font: NSFont, content: TabGroupChipLayout.Content)?

    init(group: TabGroupItem, memberCount: Int) {
        self.group = group
        self.memberCount = memberCount
        let none: [String: any CAAction] = [
            "bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "opacity": NSNull(),
            "string": NSNull(), "foregroundColor": NSNull(), "mask": NSNull(), "zPosition": NSNull(),
        ]
        for sublayer in [layer, pill, nameLayer, countLayer, nameMask] { sublayer.actions = none }
        pill.actions = ["backgroundColor": Self.fade, "bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(), "shadowOpacity": Self.fade]
        pill.cornerCurve = .continuous
        nameMask.startPoint = CGPoint(x: 0, y: 0.5)
        nameMask.endPoint = CGPoint(x: 1, y: 0.5)
        nameMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        layer.zPosition = 1
        layer.addSublayer(pill)
        pill.addSublayer(nameLayer)
        pill.addSublayer(countLayer)
        accessibility.setAccessibilityRole(.disclosureTriangle)
        accessibility.setAccessibilitySubrole(nil)
        contentChanged()
    }

    /// Takes its duration from the `Motion.transaction` it runs in.
    private static let fade = Motion.fadeAction

    var frame: CGRect {
        get { layer.frame }
        set {
            let resized = layer.frame.size != newValue.size
            layer.frame = newValue
            if resized { layoutLayers() }
        }
    }

    func update(group: TabGroupItem, memberCount: Int) {
        guard group != self.group || memberCount != self.memberCount else { return }
        self.group = group
        self.memberCount = memberCount
        contentChanged()
    }

    private var showsCount: Bool { group.isCollapsed || alwaysShowsCount }
    private var countText: String { showsCount ? String(memberCount) : "" }

    /// Measured content; drives the chip's slot width.
    var content: TabGroupChipLayout.Content {
        if let measured, measured.name == group.name, measured.count == countText, measured.font == font {
            return measured.content
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let name = group.name.isEmpty ? 0 : ceil((group.name as NSString).size(withAttributes: attributes).width)
        let count = showsCount ? ceil((countText as NSString).size(withAttributes: attributes).width) : nil
        let content = TabGroupChipLayout.Content(nameWidth: name, countWidth: count)
        measured = (group.name, countText, font, content)
        return content
    }

    var slotWidth: CGFloat { TabGroupChipLayout.slotWidth(content, metrics: metrics) }

    /// Pill frame in the root layer's coordinates.
    var pillFrame: CGRect { pill.frame }

    private func contentChanged() {
        nameLayer.string = group.name
        nameLayer.font = font
        countLayer.string = countText
        countLayer.font = font
        updateColors(animated: false)
        updateAccessibility()
        layoutLayers()
    }

    func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let m = metrics
        let bounds = CGRect(origin: .zero, size: layer.bounds.size)
        let content = content
        let height = min(m.groupChipHeight, bounds.height)
        let isDot = content.nameWidth == 0 && content.countWidth == nil
        let side = isDot ? m.groupChipDotSize : height
        let width = min(TabGroupChipLayout.pillWidth(content, metrics: m), max(0, bounds.width - 2 * m.groupChipOuterInset))
        pill.frame = pixel(CGRect(x: m.groupChipOuterInset, y: (bounds.height - side) / 2, width: width, height: side))
        pill.cornerRadius = isDot ? side / 2 : max(0, m.cornerRadius - Metrics.space1)
        pill.opacity = width > 0 ? 1 : 0

        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let textY = pixel((side - lineHeight) / 2)
        var x = m.groupChipPadding
        let nameWidth = min(content.nameWidth, max(0, width - 2 * m.groupChipPadding - (content.countWidth.map { $0 + m.groupChipCountSpacing } ?? 0)))
        nameLayer.frame = CGRect(x: pixel(x), y: textY, width: nameWidth, height: lineHeight)
        nameLayer.opacity = nameWidth > 0 ? 1 : 0
        if content.nameWidth > nameWidth, nameWidth > 0 {
            let fade = min(m.titleFadeWidth, nameWidth / 2)
            nameMask.frame = nameLayer.bounds
            nameMask.locations = [0, NSNumber(value: Double((nameWidth - fade) / nameWidth)), 1]
            nameLayer.mask = nameMask
        } else {
            nameLayer.mask = nil
        }
        if nameWidth > 0 { x += nameWidth + m.groupChipCountSpacing }
        let countWidth = content.countWidth ?? 0
        countLayer.frame = CGRect(x: pixel(x), y: textY, width: countWidth, height: lineHeight)
        countLayer.opacity = (countWidth > 0 && x + countWidth <= width) ? 1 : 0
    }

    func updateColors(animated: Bool) {
        Motion.transaction(animated ? .hover : nil) { applyColors() }
    }

    private func applyColors() {
        appearance.performAsCurrentDrawingAppearance {
            var fill = group.colorToken.fill
            if isPressed {
                fill = fill.blended(withFraction: 0.16, of: Palette.textPrimary) ?? fill
            } else if isHovered {
                fill = fill.blended(withFraction: 0.08, of: Palette.textPrimary) ?? fill
            }
            pill.backgroundColor = fill.cgColor
            nameLayer.foregroundColor = Palette.textPrimary.cgColor
            countLayer.foregroundColor = Palette.textSecondary.cgColor
        }
    }

    private func pixel(_ value: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    private func pixel(_ rect: CGRect) -> CGRect {
        CGRect(x: pixel(rect.minX), y: pixel(rect.minY), width: pixel(rect.width), height: pixel(rect.height))
    }

    private func updateAccessibility() {
        let name = group.name.isEmpty ? Strings.unnamedGroup : group.name
        let state = group.isCollapsed ? Strings.axCollapsed : Strings.axExpanded
        accessibility.setAccessibilityLabel([Strings.axGroup(name), state, Strings.groupTabCount(memberCount)].joined(separator: ", "))
        accessibility.setAccessibilityValue(group.isCollapsed ? 0 : 1)
    }
}
