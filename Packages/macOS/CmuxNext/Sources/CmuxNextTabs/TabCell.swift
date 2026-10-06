import AppKit
import CmuxNextDesign
import CmuxNextIcons
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
    /// Hover may start the title marquee (off while a drag or rename runs).
    var allowsMarquee = true { didSet { if !allowsMarquee { titleFade.stopMarquee(animated: false) } } }
    var showsSeparator = false { didSet { if oldValue != showsSeparator { separatorLayer.opacity = showsSeparator ? 1 : 0 } } }
    var style: TabStripStyle = .chrome { didSet { if oldValue != style { layoutLayers() } } }
    var metrics: TabStripMetrics = .standard {
        didSet {
            guard oldValue != metrics else { return }
            layoutLayers()
            updateColors(animated: false)
        }
    }
    /// The strip's theme scope; colors resolve against it. The strip sets it
    /// again on every theme change, so each assignment re-applies colors.
    var themeScope: ThemeScope = .app {
        didSet { updateColors(animated: false) }
    }
    /// Backing scale of the strip's window. Starts at 1 to match a new
    /// layer's `contentsScale`, so the first real assignment (2 on Retina)
    /// always reaches the layers instead of being skipped as unchanged.
    var scale: CGFloat = 1 {
        didSet {
            guard oldValue != scale else { return }
            for sublayer in [titleLayer, iconLayer, closeGlyphLayer, machineLayer].compactMap(\.self) as [CALayer] { sublayer.contentsScale = scale }
            spinnerLayer?.contentsScale = scale
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
    /// The tab's rounded pill (its background) in this cell's coordinates.
    var pillFrameInCell: CGRect { backgroundLayer.frame }

    private let backgroundLayer = CALayer()
    let iconLayer = CALayer()
    let titleLayer = ChromeTextLayer()
    /// Fades the clipped title and runs its hover marquee (one mask layer,
    /// present only while the title is clipped).
    private(set) lazy var titleFade = TitleFade(textLayer: titleLayer)
    private let separatorLayer = CALayer()
    // Created on first need and removed when unused, so 100 idle tabs cost
    // five layers each (architecture.md 3): spinner while busy, badge while
    // unread or showing status, close button on the selected/hovered tab.
    var spinnerLayer: StatusIndicatorLayer?
    var badgeLayer: CALayer?
    var closeBackgroundLayer: CALayer?
    var closeGlyphLayer: CAShapeLayer?
    /// The machine badge, created while the item names a remote machine.
    var machineLayer: ChromeTextLayer?
    var themeBadgeLayer: CALayer?
    var profileLayer: CALayer? // browser profile dot (TabCell+ProfileBadge)

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
    /// Set while a hover change lays out, so the x and the title fade.
    private var animatesCloseChange = false

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

    /// Takes its duration from the `Motion.transaction` it runs in.
    static let fade = Motion.fadeAction

    private func applyItem(previous: TabItem?) {
        if previous?.title != item.title {
            measuredTitle = nil
            titleLayer.string = displayTitle
        }
        if previous?.indicator != item.indicator || previous?.busyStyle != item.busyStyle {
            updateSpinner()
        }
        if previous?.machineBadge != item.machineBadge { updateMachineBadge() }
        if previous?.themeBadge != item.themeBadge { updateThemeBadge() }
        if previous?.profileBadge != item.profileBadge { updateProfileBadge() }
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
        // Hover shows or hides the x: its fade and the title's fade under
        // it animate (Motion `hover`); nothing moves.
        animatesCloseChange = true
        layoutLayers()
        animatesCloseChange = false
        updateMarquee()
    }

    /// The pointer resting on a clipped title scrolls it after the hover
    /// delay; leaving stops it at once (TitleFade, Motion `MotionMarquee`).
    private func updateMarquee() {
        if isHovered, allowsMarquee, !isLifted, visibility.showsTitle {
            titleFade.startMarquee()
        } else {
            titleFade.stopMarquee()
        }
    }

    private func updateLift() {
        themeScope.perform { backgroundLayer.shadowColor = Palette.shadow.cgColor }
        backgroundLayer.shadowRadius = Metrics.space3
        backgroundLayer.shadowOffset = CGSize(width: 0, height: Metrics.space1)
        backgroundLayer.shadowOpacity = isLifted ? 0.22 : 0
        layer.zPosition = isLifted ? 10 : 0
        if isLifted { titleFade.stopMarquee(animated: false) }
        updateColors(animated: true)
    }

    func updateColors(animated: Bool) {
        Motion.transaction(animated ? .hover : nil) { applyColors() }
    }

    private func applyColors() {
        themeScope.perform {
            backgroundLayer.shadowColor = Palette.shadow.cgColor
            let fill: NSColor? = (isSelected || isLifted) ? Palette.selectionFill : (isHovered ? Palette.hoverFill : nil)
            backgroundLayer.backgroundColor = fill?.cgColor
            if isLifted {
                // A lifted tab reads as solid so it does not show tabs sliding under it.
                backgroundLayer.backgroundColor = Palette.windowBackground.blended(withFraction: 0.08, of: Palette.textPrimary)?.cgColor
            }
            let text = isSelected ? Palette.textPrimary : item.isDormant ? Palette.textTertiary : Palette.textSecondary
            titleLayer.foregroundColor = text.cgColor
            machineLayer?.foregroundColor = Palette.textTertiary.cgColor
            applyProfileDotColors()
            spinnerLayer?.colors = .current(loading: StatusIndicatorAppearance.shared.config.settings.color)
            separatorLayer.backgroundColor = Palette.separator.cgColor
            iconLayer.contents = iconImage(tint: item.tint?.swatch ?? text)
        }
        applyCloseColors()
        applyBadgeColor()
    }

    /// theme-scoped: resolved by callers inside `themeScope.perform`.
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
        case .none:
            // A colored tab with no icon shows its color as a dot.
            guard item.tint != nil else { return nil }
            return TabSymbolCache.shared.image(named: "circle.fill", tint: tint, pointSize: Metrics.smallIconSize * 0.6,
                                               size: metrics.iconSize, scale: scale)
        case .image(let image): return image.cgImage
        case .agentMark(let brand):
            return TabAgentMarkCache.shared.image(brand: brand, tint: tint, size: metrics.iconSize, scale: scale)
                ?? TabPackIconCache.shared.image(name: .terminal, tint: tint, size: metrics.iconSize, scale: scale)
        case .icon(let name):
            // The pack fills the icon box; without a drawing, the catalog's SF Symbol at text size.
            return TabPackIconCache.shared.image(name: name, tint: tint, size: metrics.iconSize, scale: scale)
                ?? TabSymbolCache.shared.image(named: IconCatalog.bundled.entry(for: name)?.sf ?? "questionmark.square.dashed",
                                               tint: tint, pointSize: metrics.iconSize, size: metrics.iconSize, scale: scale)
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
    func pixel(_ value: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    func layoutLayers() {
        let slot = bounds
        let m = metrics
        // The pill leaves the gap to the next tab at its trailing side (the
        // first pill starts on the border's line); content lays out in it.
        let bounds = m.pillFrame(slotWidth: slot.width, height: slot.height)
        visibility = TabChromeVisibility.resolve(
            width: slot.width,
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
        backgroundLayer.frame = bounds
        backgroundLayer.cornerRadius = m.cornerRadius
        // The separator sits in the middle of the gap after the pill.
        separatorLayer.frame = CGRect(
            x: pixel(bounds.maxX + (slot.width - bounds.maxX - hairline) / 2),
            y: pixel((slot.height - m.separatorHeight) / 2),
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
        // A working agent keeps its brand mark, with the spinner as a small badge on it.
        let spinnerBadgesMark = spinnerLayer != nil && { if case .agentMark = item.icon { true } else { false } }()
        let showsIconArt = visibility.showsIcon && (spinnerLayer == nil || spinnerBadgesMark)
        iconLayer.frame = iconFrame
        layoutThemeBadge(iconFrame: iconFrame, visible: visibility.showsIcon)
        // A hibernated page's icon is dimmed until it is selected.
        iconLayer.opacity = showsIconArt ? (item.isDormant && !isSelected ? 0.55 : 1) : 0
        if let spinnerLayer {
            spinnerLayer.layer.opacity = visibility.showsIcon ? 1 : 0
            if spinnerBadgesMark {
                let side = pixel(iconFrame.width * 0.55)
                spinnerLayer.frame = CGRect(x: pixel(iconFrame.maxX - side + Metrics.space1), y: pixel(iconFrame.maxY - side + Metrics.space1),
                                            width: side, height: side)
            } else {
                spinnerLayer.frame = iconFrame.insetBy(dx: Metrics.space1, dy: Metrics.space1)
            }
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
            let appearing = !hasCloseLayers
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
            if appearing, animatesCloseChange {
                for layer in [closeBackgroundLayer, closeGlyphLayer] as [CALayer] {
                    Motion.set(layer, "opacity", to: Float(1), fade: .hover, from: Float(0))
                }
            }
        } else {
            removeCloseLayers()
        }
        closeButtonRect = closeRect

        if visibility.showsTitle {
            // The title always spans to the trailing inset, so it never moves
            // or resizes when the x appears; the x overlays its end and the
            // title fades out before it.
            let titleX = iconFrame.maxX + m.iconTitleSpacing
            let span = max(0, bounds.width - m.contentTrailingInset - titleX)
            let lineHeight = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
            titleLayer.opacity = 1
            let titleEnd = closeRect.map { $0.minX - m.titleCloseSpacing } ?? (bounds.width - m.contentTrailingInset)
            let visibleEnd = layoutProfileBadge(titleX: titleX, titleEnd: layoutMachineBadge(titleX: titleX, titleEnd: titleEnd, midY: midY), midY: midY)
            // The marquee fades glyphs out across the icon-title gap.
            let geometry = TitleFadeGeometry(
                textWidth: titleWidth(), span: span, visibleWidth: visibleEnd - titleX,
                leadingPadding: m.iconTitleSpacing, trailingPadding: 0, fadeWidth: m.titleFadeWidth
            )
            let frame = CGRect(x: pixel(titleX), y: pixel(midY - lineHeight / 2), width: span, height: lineHeight)
            titleFade.apply(geometry, frame: frame, animated: animatesCloseChange)
        } else {
            titleFade.stopMarquee(animated: false)
            titleLayer.opacity = 0
            titleLayer.mask = nil
            machineLayer?.opacity = 0
            profileLayer?.opacity = 0
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
