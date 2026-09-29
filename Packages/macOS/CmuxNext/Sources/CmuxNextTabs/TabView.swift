import AppKit
import CmuxNextDesign
import QuartzCore

/// One tab, drawn entirely with layers. The strip owns all mouse handling and
/// sets this view's frame every animation frame; `layout()` repositions the
/// sublayers synchronously so width animations never lag behind the content.
final class TabView: NSView {
    private(set) var item: TabItem
    var isSelected = false { didSet { if oldValue != isSelected { stateChanged() } } }
    var isHovered = false { didSet { if oldValue != isHovered { stateChanged() } } }
    var isCloseHovered = false { didSet { if oldValue != isCloseHovered { updateColors(animated: true) } } }
    var isClosePressed = false { didSet { if oldValue != isClosePressed { updateColors(animated: false) } } }
    var isLifted = false { didSet { if oldValue != isLifted { updateLift() } } }
    var showsSeparator = false { didSet { if oldValue != showsSeparator { separatorLayer.opacity = showsSeparator ? 1 : 0 } } }
    var style: TabStripStyle = .chrome { didSet { if oldValue != style { needsLayout = true } } }
    var metrics: TabStripMetrics = .standard { didSet { if oldValue != metrics { needsLayout = true } } }

    private let backgroundLayer = CALayer()
    private let iconLayer = CALayer()
    private let spinnerLayer = CAShapeLayer()
    private let badgeLayer = CALayer()
    private let titleLayer = CATextLayer()
    private let titleMask = CAGradientLayer()
    private let closeBackgroundLayer = CALayer()
    private let closeGlyphLayer = CAShapeLayer()
    private let separatorLayer = CALayer()

    private(set) var visibility = TabChromeVisibility(showsIcon: true, showsTitle: true, showsClose: false, centersContent: false)
    /// Close button frame in this view's coordinates, or nil when hidden.
    private(set) var closeButtonRect: CGRect?

    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    private var measuredTitle: (String, CGFloat)?

    init(item: TabItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        buildLayers()
        applyItem(previous: nil)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXTabButton"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    // The strip handles every event; tabs are never hit-test targets.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(item newItem: TabItem) {
        guard newItem != item else { return }
        let previous = item
        item = newItem
        applyItem(previous: previous)
    }

    // MARK: - Layers

    private func buildLayers() {
        guard let root = layer else { return }
        root.masksToBounds = false
        backgroundLayer.cornerRadius = Metrics.itemCornerRadius
        backgroundLayer.cornerCurve = .continuous
        iconLayer.contentsGravity = .resizeAspect
        spinnerLayer.fillColor = nil
        spinnerLayer.lineWidth = 1.6
        spinnerLayer.lineCap = .round
        spinnerLayer.strokeStart = 0
        spinnerLayer.strokeEnd = 0.72
        badgeLayer.cornerRadius = 3
        titleLayer.font = Self.titleFont
        titleLayer.fontSize = Self.titleFont.pointSize
        titleLayer.isWrapped = false
        titleLayer.truncationMode = .none
        titleLayer.alignmentMode = .left
        titleMask.startPoint = CGPoint(x: 0, y: 0.5)
        titleMask.endPoint = CGPoint(x: 1, y: 0.5)
        titleMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        closeBackgroundLayer.cornerRadius = 4
        closeBackgroundLayer.cornerCurve = .continuous
        closeGlyphLayer.fillColor = nil
        closeGlyphLayer.lineWidth = 1.3
        closeGlyphLayer.lineCap = .round
        separatorLayer.opacity = 0
        for sublayer in [backgroundLayer, separatorLayer, iconLayer, spinnerLayer, badgeLayer, titleLayer, closeBackgroundLayer, closeGlyphLayer] {
            sublayer.actions = Self.noActions
            root.addSublayer(sublayer)
        }
        // Fills fade; geometry never implicitly animates.
        backgroundLayer.actions = ["backgroundColor": Self.fade, "shadowOpacity": Self.fade, "bounds": NSNull(), "position": NSNull()]
        closeBackgroundLayer.actions = ["backgroundColor": Self.fade, "bounds": NSNull(), "position": NSNull()]
        separatorLayer.actions = ["opacity": Self.fade, "bounds": NSNull(), "position": NSNull()]
    }

    private static let noActions: [String: any CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "opacity": NSNull(),
        "hidden": NSNull(), "string": NSNull(), "foregroundColor": NSNull(), "backgroundColor": NSNull(),
        "mask": NSNull(), "path": NSNull(), "strokeColor": NSNull(), "sublayers": NSNull(),
    ]

    private static let fade: CABasicAnimation = {
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
        needsLayout = true
    }

    private var displayTitle: String {
        item.title.isEmpty ? Strings.untitled : item.title
    }

    private func stateChanged() {
        updateColors(animated: true)
        updateAccessibility()
        needsLayout = true
    }

    private func updateLift() {
        backgroundLayer.shadowColor = NSColor.black.cgColor
        backgroundLayer.shadowRadius = 6
        backgroundLayer.shadowOffset = CGSize(width: 0, height: 2)
        backgroundLayer.shadowOpacity = isLifted ? 0.22 : 0
        layer?.zPosition = isLifted ? 10 : 0
        updateColors(animated: true)
    }

    private func updateSpinner() {
        let key = "spin"
        if item.isBusy {
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
            spinnerLayer.removeAnimation(forKey: key)
        }
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for sublayer in [titleLayer, iconLayer] as [CALayer] { sublayer.contentsScale = scale }
        updateColors(animated: false)
    }

    override func updateLayer() {
        updateColors(animated: false)
    }

    private func updateColors(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor? = (isSelected || isLifted) ? Palette.selectionFill : (isHovered ? Palette.hoverFill : nil)
            backgroundLayer.backgroundColor = fill?.cgColor
            if isLifted {
                // A lifted tab reads as solid so it does not show tabs sliding under it.
                backgroundLayer.backgroundColor = Palette.windowBackground.blended(withFraction: 0.08, of: Palette.textPrimary)?.cgColor
            }
            let text = isSelected ? Palette.textPrimary : Palette.textSecondary
            titleLayer.foregroundColor = text.cgColor
            spinnerLayer.strokeColor = Palette.textSecondary.cgColor
            closeGlyphLayer.strokeColor = (isCloseHovered ? Palette.textPrimary : Palette.textSecondary).cgColor
            closeBackgroundLayer.backgroundColor = isClosePressed
                ? Palette.selectionFill.cgColor
                : (isCloseHovered ? Palette.hoverFill.cgColor : nil)
            separatorLayer.backgroundColor = Palette.separator.cgColor
            badgeLayer.backgroundColor = badgeColor?.cgColor
            iconLayer.contents = iconImage(tint: text)
        }
        CATransaction.commit()
    }

    private var badgeColor: NSColor? {
        switch item.status {
        case .needsInput: return .systemOrange
        case .success: return .systemGreen
        case .failure: return .systemRed
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
                pointSize: 12,
                size: metrics.iconSize,
                scale: window?.backingScaleFactor ?? 2
            )
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        layoutLayers()
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

        backgroundLayer.frame = bounds.insetBy(dx: m.tabBackgroundInset, dy: 0)
        separatorLayer.frame = CGRect(x: bounds.width - 0.5, y: (bounds.height - 16) / 2, width: 1, height: 16)

        let midY = bounds.height / 2
        let iconSide = m.iconSize
        var iconX = m.contentLeadingInset
        var closeRect: CGRect?
        if visibility.showsClose {
            let side = m.closeButtonSize
            let x = visibility.showsIcon || !visibility.centersContent
                ? bounds.width - m.contentTrailingInset - side
                : (bounds.width - side) / 2
            closeRect = CGRect(x: x, y: midY - side / 2, width: side, height: side)
        }
        if visibility.centersContent, visibility.showsIcon {
            iconX = visibility.showsClose
                ? max(m.contentLeadingInset / 2, (bounds.width - m.closeButtonSize - m.contentTrailingInset - iconSide) / 2)
                : (bounds.width - iconSide) / 2
        }
        let iconFrame = CGRect(x: iconX, y: midY - iconSide / 2, width: iconSide, height: iconSide)
        let showsIconArt = visibility.showsIcon && !item.isBusy
        iconLayer.frame = iconFrame
        iconLayer.opacity = showsIconArt ? 1 : 0
        spinnerLayer.opacity = (visibility.showsIcon && item.isBusy) ? 1 : 0
        let spinnerRect = iconFrame.insetBy(dx: 2, dy: 2)
        spinnerLayer.bounds = CGRect(origin: .zero, size: spinnerRect.size)
        spinnerLayer.position = CGPoint(x: spinnerRect.midX, y: spinnerRect.midY)
        spinnerLayer.path = CGPath(ellipseIn: spinnerLayer.bounds, transform: nil)

        let badgeSide: CGFloat = 6
        badgeLayer.frame = CGRect(x: iconFrame.maxX - badgeSide + 2, y: iconFrame.minY - 2, width: badgeSide, height: badgeSide)
        badgeLayer.opacity = (visibility.showsIcon && badgeColor != nil) ? 1 : 0

        if let closeRect {
            closeBackgroundLayer.frame = closeRect
            let glyph = closeRect.insetBy(dx: 5.5, dy: 5.5)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: glyph.minX, y: glyph.minY))
            path.addLine(to: CGPoint(x: glyph.maxX, y: glyph.maxY))
            path.move(to: CGPoint(x: glyph.maxX, y: glyph.minY))
            path.addLine(to: CGPoint(x: glyph.minX, y: glyph.maxY))
            closeGlyphLayer.frame = bounds
            closeGlyphLayer.path = path
            closeGlyphLayer.opacity = 1
            closeBackgroundLayer.opacity = 1
        } else {
            closeGlyphLayer.opacity = 0
            closeBackgroundLayer.opacity = 0
        }
        closeButtonRect = closeRect

        if visibility.showsTitle {
            let titleX = iconFrame.maxX + m.iconTitleSpacing
            let titleEnd = (closeRect.map { $0.minX - m.titleCloseSpacing }) ?? (bounds.width - m.contentTrailingInset)
            let width = max(0, titleEnd - titleX)
            let lineHeight = ceil(Self.titleFont.ascender - Self.titleFont.descender + Self.titleFont.leading)
            titleLayer.frame = CGRect(x: titleX, y: (midY - lineHeight / 2).rounded(), width: width, height: lineHeight)
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
        let width = ceil((title as NSString).size(withAttributes: [.font: Self.titleFont]).width)
        measuredTitle = (title, width)
        return width
    }

    // MARK: - Accessibility

    private func updateAccessibility() {
        var parts = [displayTitle]
        if item.isPinned { parts.append(Strings.axPinned) }
        if item.isBusy { parts.append(Strings.axBusy) }
        switch item.status {
        case .needsInput: parts.append(Strings.axNeedsInput)
        case .success: parts.append(Strings.axSuccess)
        case .failure: parts.append(Strings.axFailure)
        case .none: if item.isUnread { parts.append(Strings.axUnread) }
        }
        setAccessibilityLabel(parts.joined(separator: ", "))
        setAccessibilityValue(isSelected ? 1 : 0)
        setAccessibilityHelp(item.subtitle)
    }

    var onAccessibilityPress: (() -> Void)?
    var onAccessibilityClose: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        onAccessibilityPress?()
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: Strings.axClose) { [weak self] in
            self?.onAccessibilityClose?()
            return true
        }]
    }

    /// Image of this tab for the drag session.
    func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }
}

/// Tinted SF Symbol images, cached per name, tint, and scale.
final class TabSymbolCache {
    static let shared = TabSymbolCache()
    private var cache: [String: CGImage] = [:]

    func image(named name: String, tint: NSColor, pointSize: CGFloat, size: CGFloat, scale: CGFloat) -> CGImage? {
        let resolved = tint.usingColorSpace(.sRGB) ?? tint
        let key = "\(name)|\(resolved.redComponent)|\(resolved.greenComponent)|\(resolved.blueComponent)|\(resolved.alphaComponent)|\(pointSize)|\(size)|\(scale)"
        if let cached = cache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [resolved]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return nil
        }
        let pixels = Int((size * scale).rounded())
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let symbolSize = symbol.size
        let ratio = min(size / symbolSize.width, size / symbolSize.height, 1)
        let drawSize = CGSize(width: symbolSize.width * ratio, height: symbolSize.height * ratio)
        symbol.draw(in: CGRect(x: (size - drawSize.width) / 2, y: (size - drawSize.height) / 2, width: drawSize.width, height: drawSize.height))
        NSGraphicsContext.restoreGraphicsState()
        let image = context.makeImage()
        if cache.count > 256 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
