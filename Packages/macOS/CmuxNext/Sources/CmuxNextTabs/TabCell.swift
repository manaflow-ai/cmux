import AppKit
import CmuxNextDesign
import QuartzCore

/// One tab, drawn entirely with CALayers inside the strip's single view (no
/// NSView per tab). The strip owns all mouse handling and sets `frame` every
/// animation frame; `layoutLayers()` repositions the sublayers synchronously
/// so width animations never lag behind the content.
final class TabCell {
    /// Root layer, a sublayer of the strip's tab clip layer.
    let layer = CALayer()
    /// VoiceOver and automation element for this tab.
    let accessibility = TabAccessibilityElement()

    private(set) var item: TabItem
    var isSelected = false { didSet { if oldValue != isSelected { stateChanged() } } }
    var isHovered = false { didSet { if oldValue != isHovered { stateChanged() } } }
    var isCloseHovered = false { didSet { if oldValue != isCloseHovered { updateColors(animated: true) } } }
    var isClosePressed = false { didSet { if oldValue != isClosePressed { updateColors(animated: false) } } }
    var isLifted = false { didSet { if oldValue != isLifted { updateLift() } } }
    var showsSeparator = false { didSet { if oldValue != showsSeparator { separatorLayer.opacity = showsSeparator ? 1 : 0 } } }
    var style: TabStripStyle = .chrome { didSet { if oldValue != style { layoutLayers() } } }
    var metrics: TabStripMetrics = .standard {
        didSet {
            guard oldValue != metrics else { return }
            layoutLayers()
            updateColors(animated: false)
        }
    }
    /// The strip's effective appearance; colors resolve against it.
    var appearance = NSAppearance.currentDrawing() {
        didSet { if oldValue !== appearance { updateColors(animated: false) } }
    }
    /// Backing scale of the strip's window. Starts at 1 to match a new
    /// layer's `contentsScale`, so the first real assignment (2 on Retina)
    /// always reaches the layers instead of being skipped as unchanged.
    var scale: CGFloat = 1 {
        didSet {
            guard oldValue != scale else { return }
            for sublayer in [titleLayer, iconLayer, spinnerLayer, closeGlyphLayer].compactMap(\.self) as [CALayer] { sublayer.contentsScale = scale }
            updateColors(animated: false)
            layoutLayers()
        }
    }

    var frame: CGRect {
        get { layer.frame }
        set {
            let resized = layer.frame.size != newValue.size
            layer.frame = newValue
            if resized { layoutLayers() }
        }
    }

    var bounds: CGRect { CGRect(origin: .zero, size: layer.bounds.size) }

    private let backgroundLayer = CALayer()
    let iconLayer = CALayer()
    let titleLayer = ChromeTextLayer()
    private let titleMask = CAGradientLayer()
    private let separatorLayer = CALayer()
    // Created on first need and removed when unused, so 100 idle tabs cost
    // five layers each (architecture.md 3): spinner while busy, badge while
    // unread or showing status, close button on the selected/hovered tab.
    var spinnerLayer: CAShapeLayer?
    var badgeLayer: CALayer?
    var closeBackgroundLayer: CALayer?
    var closeGlyphLayer: CAShapeLayer?

    var hasSpinnerLayer: Bool { spinnerLayer != nil }
    var hasBadgeLayer: Bool { badgeLayer != nil }
    var hasCloseLayers: Bool { closeBackgroundLayer != nil || closeGlyphLayer != nil }

    private(set) var visibility = TabChromeVisibility(showsIcon: true, showsTitle: true, showsClose: false, centersContent: false)
    /// Close button frame in this view's coordinates, or nil when hidden.
    private(set) var closeButtonRect: CGRect?

    /// Title font; the strip updates it when the chrome font size changes.
    var titleFont = Typography.body {
        didSet {
            guard titleFont != oldValue else { return }
            titleLayer.font = titleFont
            measuredTitle = nil
            layoutLayers()
        }
    }
    private var measuredTitle: (String, CGFloat)?

    init(item: TabItem) {
        self.item = item
        layer.actions = Self.noActions
        buildLayers()
        applyItem(previous: nil)
    }

    func update(item newItem: TabItem) {
        guard newItem != item else { return }
        let previous = item
        item = newItem
        applyItem(previous: previous)
    }

    // MARK: - Layers

    private func buildLayers() {
        let root = layer
        root.masksToBounds = false
        backgroundLayer.cornerCurve = .continuous
        iconLayer.contentsGravity = .resizeAspect
        titleLayer.font = titleFont
        titleMask.startPoint = CGPoint(x: 0, y: 0.5)
        titleMask.endPoint = CGPoint(x: 1, y: 0.5)
        titleMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        separatorLayer.opacity = 0
        for sublayer in [backgroundLayer, separatorLayer, iconLayer, titleLayer] {
            sublayer.actions = Self.noActions
            root.addSublayer(sublayer)
        }
        // Fills fade; geometry never implicitly animates.
        backgroundLayer.actions = ["backgroundColor": Self.fade, "shadowOpacity": Self.fade, "bounds": NSNull(), "position": NSNull()]
        separatorLayer.actions = ["opacity": Self.fade, "bounds": NSNull(), "position": NSNull()]
    }

    static let noActions: [String: any CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "opacity": NSNull(),
        "hidden": NSNull(), "string": NSNull(), "foregroundColor": NSNull(), "backgroundColor": NSNull(),
        "mask": NSNull(), "path": NSNull(), "strokeColor": NSNull(), "sublayers": NSNull(),
    ]

    static let fade: CABasicAnimation = {
        let animation = CABasicAnimation()
        animation.duration = 0.14
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return animation
    }()

    private func applyItem(previous: TabItem?) {
        if previous?.title != item.title {
            measuredTitle = nil
            titleLayer.string = displayTitle
        }
        if previous?.isBusy != item.isBusy { updateSpinner() }
        updateColors(animated: false)
        updateAccessibility()
        layoutLayers()
    }

    var displayTitle: String {
        item.title.isEmpty ? Strings.untitled : item.title
    }

    private func stateChanged() {
        updateColors(animated: true)
        updateAccessibility()
        layoutLayers()
    }

    private func updateLift() {
        backgroundLayer.shadowColor = Palette.shadow.cgColor
        backgroundLayer.shadowRadius = Metrics.space3
        backgroundLayer.shadowOffset = CGSize(width: 0, height: Metrics.space1)
        backgroundLayer.shadowOpacity = isLifted ? 0.22 : 0
        layer.zPosition = isLifted ? 10 : 0
        updateColors(animated: true)
    }

    private func updateSpinner() {
        let key = "spin"
        if item.isBusy {
            let spinnerLayer = makeSpinner()
            if spinnerLayer.animation(forKey: key) == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -2 * CGFloat.pi
                spin.duration = 0.9
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                spinnerLayer.add(spin, forKey: key)
            }
        } else {
            spinnerLayer?.removeFromSuperlayer()
            spinnerLayer = nil
        }
        layoutLayers()
    }

    func updateColors(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        appearance.performAsCurrentDrawingAppearance {
            let fill: NSColor? = (isSelected || isLifted) ? Palette.selectionFill : (isHovered ? Palette.hoverFill : nil)
            backgroundLayer.backgroundColor = fill?.cgColor
            if isLifted {
                // A lifted tab reads as solid so it does not show tabs sliding under it.
                backgroundLayer.backgroundColor = Palette.windowBackground.blended(withFraction: 0.08, of: Palette.textPrimary)?.cgColor
            }
            let text = isSelected ? Palette.textPrimary : Palette.textSecondary
            titleLayer.foregroundColor = text.cgColor
            spinnerLayer?.strokeColor = Palette.textSecondary.cgColor
            separatorLayer.backgroundColor = Palette.separator.cgColor
            iconLayer.contents = iconImage(tint: text)
        }
        applyCloseColors()
        applyBadgeColor()
        CATransaction.commit()
    }

    var badgeColor: NSColor? {
        switch item.status {
        case .needsInput: return Palette.attention
        case .success: return Palette.success
        case .failure: return Palette.danger
        case .none: return item.isUnread ? Palette.textPrimary : nil
        }
    }

    private func iconImage(tint: NSColor) -> CGImage? {
        switch item.icon {
        case .none: return nil
        case .image(let image): return image.cgImage
        case .symbol(let name):
            return TabSymbolCache.shared.image(
                named: name,
                tint: tint,
                pointSize: Metrics.smallIconSize,
                size: metrics.iconSize,
                scale: scale
            )
        }
    }

    // MARK: - Layout

    /// Rounds to the device pixel grid so icons, glyphs, and hairlines stay crisp.
    private func pixel(_ value: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    func layoutLayers() {
        let bounds = bounds
        let m = metrics
        visibility = TabChromeVisibility.resolve(
            width: bounds.width,
            isPinned: item.isPinned,
            isSelected: isSelected,
            isHovered: isHovered,
            style: style,
            metrics: m
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let hairline = 1 / scale
        backgroundLayer.frame = bounds.insetBy(dx: m.tabBackgroundInset, dy: 0)
        backgroundLayer.cornerRadius = m.cornerRadius
        separatorLayer.frame = CGRect(
            x: pixel(bounds.width) - hairline,
            y: pixel((bounds.height - m.separatorHeight) / 2),
            width: hairline,
            height: m.separatorHeight
        )

        let midY = bounds.height / 2
        let iconSide = m.iconSize
        var iconX = m.contentLeadingInset
        var closeRect: CGRect?
        if visibility.showsClose {
            let side = m.closeButtonSize
            let x = visibility.showsIcon || !visibility.centersContent
                ? bounds.width - m.contentTrailingInset - side
                : (bounds.width - side) / 2
            closeRect = CGRect(x: pixel(x), y: pixel(midY - side / 2), width: side, height: side)
        }
        if visibility.centersContent, visibility.showsIcon {
            iconX = visibility.showsClose
                ? max(m.contentLeadingInset / 2, (bounds.width - m.closeButtonSize - m.contentTrailingInset - iconSide) / 2)
                : (bounds.width - iconSide) / 2
        }
        let iconFrame = CGRect(x: pixel(iconX), y: pixel(midY - iconSide / 2), width: iconSide, height: iconSide)
        let showsIconArt = visibility.showsIcon && !item.isBusy
        iconLayer.frame = iconFrame
        iconLayer.opacity = showsIconArt ? 1 : 0
        if let spinnerLayer {
            spinnerLayer.opacity = visibility.showsIcon ? 1 : 0
            let spinnerRect = iconFrame.insetBy(dx: Metrics.space1, dy: Metrics.space1)
            if spinnerLayer.bounds.size != spinnerRect.size {
                spinnerLayer.bounds = CGRect(origin: .zero, size: spinnerRect.size)
                spinnerLayer.path = CGPath(ellipseIn: spinnerLayer.bounds, transform: nil)
            }
            spinnerLayer.position = CGPoint(x: spinnerRect.midX, y: spinnerRect.midY)
        }

        if visibility.showsIcon, badgeColor != nil {
            let badgeLayer = makeBadge()
            let badge = m.badgeSize
            badgeLayer.frame = CGRect(
                x: pixel(iconFrame.maxX - badge + Metrics.space1),
                y: pixel(iconFrame.minY - Metrics.space1),
                width: badge,
                height: badge
            )
            badgeLayer.cornerRadius = badge / 2
        } else if let badgeLayer {
            badgeLayer.removeFromSuperlayer()
            self.badgeLayer = nil
        }

        if let closeRect {
            let (closeBackgroundLayer, closeGlyphLayer) = makeCloseLayers()
            closeBackgroundLayer.frame = closeRect
            closeBackgroundLayer.cornerRadius = max(0, m.cornerRadius - Metrics.space1)
            let inset = (closeRect.width - m.closeGlyphSize) / 2
            let glyph = closeRect.insetBy(dx: inset, dy: inset)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: glyph.minX, y: glyph.minY))
            path.addLine(to: CGPoint(x: glyph.maxX, y: glyph.maxY))
            path.move(to: CGPoint(x: glyph.maxX, y: glyph.minY))
            path.addLine(to: CGPoint(x: glyph.minX, y: glyph.maxY))
            closeGlyphLayer.frame = bounds
            closeGlyphLayer.path = path
        } else {
            removeCloseLayers()
        }
        closeButtonRect = closeRect

        if visibility.showsTitle {
            let titleX = iconFrame.maxX + m.iconTitleSpacing
            let titleEnd = (closeRect.map { $0.minX - m.titleCloseSpacing }) ?? (bounds.width - m.contentTrailingInset)
            let width = max(0, titleEnd - titleX)
            let lineHeight = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
            titleLayer.frame = CGRect(x: pixel(titleX), y: pixel(midY - lineHeight / 2), width: width, height: lineHeight)
            titleLayer.opacity = 1
            let textWidth = titleWidth()
            if textWidth > width, width > 0 {
                // Clipped titles fade out instead of showing an ellipsis.
                let fade = min(m.titleFadeWidth, width * 0.5)
                let start = max(0, (width - fade) / width)
                titleMask.frame = titleLayer.bounds
                titleMask.locations = [0, NSNumber(value: Double(start)), 1]
                titleLayer.mask = titleMask
            } else {
                titleLayer.mask = nil
            }
        } else {
            titleLayer.opacity = 0
        }
    }

    private func titleWidth() -> CGFloat {
        let title = displayTitle
        if let measuredTitle, measuredTitle.0 == title { return measuredTitle.1 }
        let width = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        measuredTitle = (title, width)
        return width
    }
}
