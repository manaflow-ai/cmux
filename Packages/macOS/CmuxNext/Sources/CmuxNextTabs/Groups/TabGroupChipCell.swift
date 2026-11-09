import AppKit
import CmuxNextDesign
import QuartzCore

/// A group chip drawn with CALayers: a pill of the group's color with the
/// group's icon and name (or a dot with neither) and, when collapsed, the
/// member count. Used by the strip and the saved groups bar. The pill is the
/// sidebar group headers' tinted glass with a rim (#36225, ``GroupChipGlass``)
/// unless `sidebar.groupHeader.background` asks for solid; the look changes
/// only the pill's fill, rim and ink, never its size.
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
            themeScope.perform { pill.shadowColor = Palette.shadow.cgColor }
            let elevation = PopupStyle.elevation2
            pill.shadowRadius = elevation.layerRadius
            pill.shadowOffset = elevation.layerOffset(flipped: true)
            pill.shadowOpacity = isLifted ? Float(elevation.alpha) : 0
            layer.zPosition = isLifted ? 11 : 1
        }
    }
    var metrics = TabStripMetrics.standard { didSet { if oldValue != metrics { contentChanged() } } }
    var font = Typography.caption { didSet { if oldValue != font { contentChanged() } } }
    var themeScope: ThemeScope = .app { didSet { updateColors(animated: false) } }
    /// The glass settings the chip follows (`GroupChipGlass.current`); the strip sets it when they change.
    var look = GroupChipGlass.current { didSet { if oldValue != look { updateColors(animated: false) } } }
    /// Backing scale of the host window. Starts at 1 to match a new layer's
    /// `contentsScale`, so the first real assignment always reaches the layers.
    var scale: CGFloat = 1 {
        didSet {
            guard oldValue != scale else { return }
            nameLayer.contentsScale = scale
            countLayer.contentsScale = scale
            iconLayer.contentsScale = scale
            updateColors(animated: false)
        }
    }

    let pill = CALayer()
    /// The glass's specular rim: a hairline inside the pill, lit at the top and fading to the bottom
    /// (the `group` surface role's, as `GlassRimView` draws it on a sidebar header). Hidden when solid.
    let rim = CAGradientLayer()
    private let rimStroke = CAShapeLayer()
    private let nameLayer = ChromeTextLayer()
    private let nameMask = CAGradientLayer()
    private let countLayer = ChromeTextLayer()
    /// The group icon before the name, at the tab icon size (`TabStripMetrics.groupChipIconSize`).
    private let iconLayer = CALayer()
    private var measured: (name: String, count: String, font: NSFont, content: TabGroupChipLayout.Content)?
    /// The count an expanding chip still draws while its pill shrinks over
    /// it (cx-f6i7), and that count's width.
    private var leavingCount: (text: String, width: CGFloat)?

    init(group: TabGroupItem, memberCount: Int) {
        self.group = group
        self.memberCount = memberCount
        // Anchored at the leading edge, as a tab cell (a strip move of the width never moves its x).
        layer.anchorPoint = .zero
        let none: [String: any CAAction] = [
            "bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "opacity": NSNull(),
            "string": NSNull(), "foregroundColor": NSNull(), "mask": NSNull(), "zPosition": NSNull(),
        ]
        for sublayer in [layer, pill, nameLayer, countLayer, nameMask, iconLayer, rim, rimStroke] { sublayer.actions = none }
        iconLayer.contentsGravity = .resizeAspect
        pill.actions = ["backgroundColor": Self.fade, "bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(), "shadowOpacity": Self.fade,
                        "borderWidth": NSNull(), "borderColor": NSNull()]
        rim.startPoint = CGPoint(x: 0.5, y: 0)
        rim.endPoint = CGPoint(x: 0.5, y: 1)
        rimStroke.fillColor = nil
        rimStroke.strokeColor = NSColor.black.cgColor
        rim.mask = rimStroke
        pill.cornerCurve = .continuous
        nameMask.startPoint = CGPoint(x: 0, y: 0.5)
        nameMask.endPoint = CGPoint(x: 1, y: 0.5)
        nameMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        layer.zPosition = 1
        layer.addSublayer(pill)
        pill.addSublayer(iconLayer)
        pill.addSublayer(nameLayer)
        pill.addSublayer(countLayer)
        pill.addSublayer(rim)
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

    /// Measured content; drives the chip's slot width. No icon adds no width.
    var content: TabGroupChipLayout.Content {
        var content = textContent
        content.iconWidth = group.icon == nil ? 0 : metrics.groupChipIconSize
        return content
    }

    /// The measured name and count.
    private var textContent: TabGroupChipLayout.Content {
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
        // An unnamed group without an icon turns into a dot on expand: no count to cover.
        let shown = countLayer.string
        countLayer.font = font
        let keepsPill = !group.name.isEmpty || group.icon != nil
        leavingCount = countText.isEmpty && !shown.isEmpty && keepsPill ? (shown, countLayer.textWidth) : nil
        nameLayer.string = group.name
        nameLayer.font = font
        countLayer.string = leavingCount?.text ?? countText
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
        var content = content
        // A count that is going away (expand) stays drawn until the slot has
        // shrunk to the content without it; the pill's edge covers it.
        if leavingCount != nil, bounds.width <= TabGroupChipLayout.slotWidth(content, metrics: m) + 0.5 {
            leavingCount = nil
            countLayer.string = countText
        }
        if let leavingCount { content.countWidth = leavingCount.width }
        let height = min(m.groupChipHeight, bounds.height)
        let isDot = content.isDot
        let side = isDot ? m.groupChipDotSize : height
        let width = min(TabGroupChipLayout.pillWidth(content, metrics: m), max(0, bounds.width - 2 * m.groupChipOuterInset))
        pill.frame = pixel(CGRect(x: m.groupChipOuterInset, y: (bounds.height - side) / 2, width: width, height: side))
        // The chip sits on the tab pills' line: concentric with a tab pill there.
        let tabRow = CGRect(x: 0, y: (bounds.height - m.tabHeight) / 2, width: bounds.width, height: m.tabHeight)
        pill.cornerRadius = isDot ? side / 2 : m.nestedCornerRadius(pill.frame, in: tabRow)
        pill.opacity = width > 0 ? 1 : 0
        layoutRim(radius: pill.cornerRadius)

        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let textY = pixel((side - lineHeight) / 2)
        var x = m.groupChipPadding
        let iconSide = content.iconWidth, iconAdvance = TabGroupChipLayout.iconAdvance(content, metrics: m)
        iconLayer.frame = pixel(CGRect(x: x, y: (side - iconSide) / 2, width: iconSide, height: iconSide))
        iconLayer.opacity = iconSide > 0 && width >= m.groupChipPadding + iconSide ? 1 : 0
        x += iconAdvance
        // The pill is narrower than its content only while its width springs
        // (collapse, expand): the name keeps its width and the pill's edge
        // reveals or covers the count, so the name never clips (cx-f6i7).
        let fullName = min(content.nameWidth, m.groupChipMaxNameWidth)
        let nameWidth = min(fullName, max(0, width - 2 * m.groupChipPadding - iconAdvance))
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
        let shownCount = min(countWidth, max(0, width - x))
        countLayer.frame = CGRect(x: pixel(x), y: textY, width: shownCount, height: lineHeight)
        countLayer.opacity = shownCount > 0 ? 1 : 0
    }

    /// The rim follows the pill's bounds and corner on every layout, so a springing width never shows it out of place.
    private func layoutRim(radius: CGFloat) {
        let bounds = pill.bounds
        let hairline = 1 / max(scale, 1)
        rim.frame = bounds
        rimStroke.frame = bounds
        rimStroke.lineWidth = Metrics.lineWidth(hairline)
        let inset = bounds.insetBy(dx: hairline / 2, dy: hairline / 2)
        // CoreGraphics refuses a corner wider than half the rect.
        let corner = min(max(radius - hairline / 2, 0), max(min(inset.width, inset.height) / 2, 0))
        rimStroke.path = inset.width > 0 && inset.height > 0
            ? CGPath(roundedRect: inset, cornerWidth: corner, cornerHeight: corner, transform: nil) : nil
    }

    func updateColors(animated: Bool) {
        Motion.feedback.transaction(animated ? .hover : nil) { applyColors() }
    }

    private func applyColors() {
        themeScope.perform {
            pill.shadowColor = Palette.shadow.cgColor
            let tokens = themeScope.tokens
            // Hover and press step over the glass pane, as on a sidebar header (`GroupGlassPaint` steps).
            let steps = isPressed ? [tokens.pressedFill] : isHovered ? [tokens.hoverFill] : []
            let opaque = ReduceTransparency.shared.isEnabled
            if let paint = look.paint(tint: group.tint, tokens: tokens, steps: steps, opaque: opaque) {
                applyGlass(paint, tokens: tokens, opaque: opaque)
                return
            }
            var fill = group.tint.chipFill
            if isPressed {
                fill = fill.blended(withFraction: 0.16, of: Palette.textPrimary) ?? fill
            } else if isHovered {
                fill = fill.blended(withFraction: 0.08, of: Palette.textPrimary) ?? fill
            }
            pill.backgroundColor = fill.cgColor
            setEdge(rim: nil, border: nil)
            nameLayer.foregroundColor = Palette.textPrimary.cgColor
            countLayer.foregroundColor = Palette.textSecondary.cgColor
            iconLayer.contents = group.icon?.groupChipImage(tint: Palette.textPrimary, size: metrics.groupChipIconSize, scale: scale)
        }
    }

    /// The glass pill: the translucent tinted pane, its rim, and one ink held readable over it. Under Reduce
    /// Transparency the pane is opaque and edged with a hairline instead of the rim, as the sidebar's.
    private func applyGlass(_ paint: GroupGlassPaint, tokens: ThemeTokens, opaque: Bool) {
        pill.backgroundColor = paint.fill.nsColor.cgColor
        let rimColors = GroupChipGlass.rim(isDark: tokens.isDark)
        setEdge(rim: opaque ? nil : rimColors, border: opaque ? tokens.separator.nsColor : nil)
        let ink = paint.ink.nsColor
        nameLayer.foregroundColor = ink.cgColor
        countLayer.foregroundColor = ink.withAlphaComponent(Self.countInkAlpha).cgColor
        iconLayer.contents = group.icon?.groupChipImage(tint: ink, size: metrics.groupChipIconSize, scale: scale)
    }

    /// The count's share of the ink on glass: secondary, as a sidebar header's count.
    static let countInkAlpha: CGFloat = 0.7

    private func setEdge(rim colors: (top: NSColor, bottom: NSColor)?, border: NSColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.isHidden = colors == nil
        if let colors { rim.colors = [colors.top.cgColor, colors.bottom.cgColor] }
        pill.borderWidth = border == nil ? 0 : Metrics.lineWidth(1)
        pill.borderColor = border?.cgColor
        CATransaction.commit()
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
