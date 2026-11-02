import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore
/// One tab, drawn entirely with CALayers inside the strip's single view (no
/// NSView per tab). The strip owns all mouse handling and sets `frame` once
/// per change (its target); `layoutLayers()` repositions the sublayers
/// synchronously, and the strip's move animates both on one curve.
final class TabCell {
    /// Root layer, a sublayer of the strip's tab clip layer.
    let layer = CALayer()
    /// VoiceOver and automation element for this tab.
    let accessibility = TabAccessibilityElement()
    /// The strip's handler behind the element's Mute tab / Unmute tab action.
    var accessibilityToggleAudio: (@MainActor () -> Void)? { didSet { updateAccessibility() } }
    /// The strip's handler behind the element's Exit Zoom action, while the tab shows the zoom indicator.
    var accessibilityToggleZoom: (@MainActor () -> Void)? { didSet { updateAccessibility() } }
    private(set) var item: TabItem
    /// Instant (L4): the content switches in one frame, so the highlight does too.
    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            updateStacking()
            stateChanged(animated: false)
        }
    }
    /// One of several selected tabs (Cmd- or Shift-click) that is not the active one: a lighter
    /// fill than the active tab's (`Palette.secondarySelectionFill`, Chrome's selected tabs).
    var isMultiSelected = false { didSet { if oldValue != isMultiSelected { stateChanged(animated: false) } } }
    var isHovered = false { didSet { if oldValue != isHovered { stateChanged() } } }
    var isCloseHovered = false { didSet { if oldValue != isCloseHovered { updateColors(animated: true, showing: isCloseHovered) } } }
    var isClosePressed = false { didSet { if oldValue != isClosePressed { updateColors(animated: false) } } }
    /// The pointer is on the speaker button, or presses it (TabCell+AudioBadge).
    var isAudioHovered = false { didSet { if oldValue != isAudioHovered { updateColors(animated: true, showing: isAudioHovered) } } }
    var isAudioPressed = false { didSet { if oldValue != isAudioPressed { updateColors(animated: false) } } }
    /// The selected tab of a zoomed pane: it shows the zoom indicator (TabCell+ZoomBadge).
    var showsZoom = false {
        didSet {
            guard oldValue != showsZoom else { return }
            updateZoomBadge()
            updateColors(animated: false)
            layoutLayers()
            updateAccessibility()
        }
    }
    /// The pointer is on the zoom indicator, or presses it (TabCell+ZoomBadge).
    var isZoomHovered = false { didSet { if oldValue != isZoomHovered { updateColors(animated: true, showing: isZoomHovered) } } }
    var isZoomPressed = false { didSet { if oldValue != isZoomPressed { updateColors(animated: false) } } }
    var isLifted = false { didSet { if oldValue != isLifted { updateLift() } } }
    /// The strip's window is main (in front); off, the selected tab's fill is dimmer (never
    /// gone: a pane's active tab always looks active), so only it repaints.
    var isWindowMain = true { didSet { if oldValue != isWindowMain, isSelected { updateColors(animated: false) } } }
    /// The strip's window is on screen and not fully covered: a busy indicator spins only then
    /// (cx-qtgj2: a minimized or covered window costs no spinner frames).
    var isWindowVisible = true { didSet { if oldValue != isWindowVisible, item.isBusy { updateSpinner() } } }
    /// The strip shows in its window (not a parked workspace's strip or a hidden screen bar). An
    /// app-wide indicator resync (the app coming back to the front) reaches the cell only then, so
    /// an activation costs the tabs on screen, not every busy tab of the session; a resync that
    /// came while hidden runs when the strip shows again.
    var isStripShown = true {
        didSet { if isStripShown, !oldValue, owesIndicatorResync { statusIndicatorResync() } }
    }
    /// A resync arrived while the strip was hidden (TabCell+StatusIndicator).
    var owesIndicatorResync = false
    /// The selected (or lifted) tab's fill shows: always for the pane's active tab, in a
    /// background window too (Lawrence 2026-10-20, a tab with no pill read as inactive).
    var fillsSelection: Bool { isSelected || isLifted }
    /// The share of the selected fill's alpha a background window's active tab keeps.
    static let backgroundWindowSelectionShare: CGFloat = 0.55
    /// Hover may start the title marquee (off while a drag or rename runs).
    var allowsMarquee = true { didSet { if !allowsMarquee { titleFade.stopMarquee(animated: false) } } }
    /// A closing tab keeps the content it showed when the close began
    /// (`TabCell+Motion`).
    var isClosing = false { didSet { if oldValue != isClosing { closingChanged() } } }
    var closingVisibility: TabChromeVisibility?
    /// The parts following a moving width (`TabCell+InnerPath`); nil at rest.
    var innerPath: InnerPath?
    /// The title's geometry of the last `layoutParts(onPath: true)` sample; nil when it hides there.
    var pathTitle: TitleFade.Sample?
    /// Created on the first occlusion (`occlude(visible:)`).
    private(set) var occlusionMaskIfMade: CALayer?
    var occlusionMask: CALayer {
        if let occlusionMaskIfMade { return occlusionMaskIfMade }
        let mask = CALayer()
        occlusionMaskIfMade = mask
        return mask
    }
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
            for sublayer in [titleLayer, iconLayer, closeGlyphLayer, machineLayer, hibernationRingLayer].compactMap(\.self) as [CALayer] { sublayer.contentsScale = scale }
            spinnerLayer?.contentsScale = scale
            updateColors(animated: false)
            layoutLayers()
        }
    }
    var frame: CGRect {
        get { layer.frame }
        set { setFrame(newValue, laysOut: true) }
    }

    /// `laysOut` false: the caller adds the strip move of the new size first, then calls
    /// `layoutLayers()`, so the parts follow the path once (`TabStripView.applyFrames`).
    func setFrame(_ frame: CGRect, laysOut: Bool) {
        let resized = layer.frame.size != frame.size
        layer.frame = frame
        if resized, laysOut { layoutLayers() }
    }

    var bounds: CGRect { CGRect(origin: .zero, size: layer.bounds.size) }
    /// The tab's rounded pill (its background) in this cell's coordinates.
    var pillFrameInCell: CGRect { backgroundLayer.frame }

    let backgroundLayer = CALayer()
    let iconLayer = CALayer()
    let titleLayer = ChromeTextLayer()
    let separatorLayer = TabCell.makeSeparatorLayer()
    /// Fades the clipped title and runs its hover marquee (one mask layer,
    /// present only while the title is clipped).
    private(set) lazy var titleFade = TitleFade(textLayer: titleLayer, gate: Motion.tabs)
    // Created on first need and removed when unused, so 100 idle tabs cost
    // five layers each (architecture.md 3): spinner while busy, badge while
    // unread or showing status, close button on the selected/hovered tab.
    var spinnerLayer: StatusIndicatorLayer?
    var isSpinnerExiting = false
    var badgeLayer: CALayer?
    var statusGlyphLayer: StatusIndicatorLayer? // a status icon set's badge mark (TabCell+StatusBadge)
    var closeBackgroundLayer: CALayer?
    var closeGlyphLayer: CAShapeLayer?
    /// The machine badge, created while the item names a remote machine.
    var machineLayer: ChromeTextLayer?
    var themeBadgeLayer: CALayer?
    var profileLayer: CALayer? // browser profile dot (TabCell+ProfileBadge)
    var presenceLayer: CALayer? // the acting agent's dot (TabCell+PresenceDot)
    var audioLayer: CALayer? // speaker of a tab playing sound (TabCell+AudioBadge)
    var audioBackgroundLayer: CALayer? // the speaker button's hover and press fill
    var zoomLayer: CALayer? // a zoomed pane's indicator on its selected tab (TabCell+ZoomBadge)
    var zoomBackgroundLayer: CALayer? // the zoom indicator's hover and press fill
    var hibernationRingLayer: CAShapeLayer? // dotted ring of a hibernated tab (TabCell+HibernationRing)

    var hasCloseLayers: Bool { closeBackgroundLayer != nil || closeGlyphLayer != nil }

    private(set) var visibility = TabChromeVisibility(showsIcon: true, showsTitle: true, showsClose: false, centersContent: false)
    /// Close button frame in this view's coordinates, or nil when hidden. Set with `setCloseButtonRect(_:pill:)`.
    var closeButtonRect: CGRect?

    /// Title font; the strip updates it when the tab or chrome font size changes.
    var titleFont = Typography.tabTitle {
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
        // Anchored at the leading edge: a strip move of the width never moves the tab's x, so a
        // dragged tab whose width still moves keeps its edge under the pointer.
        layer.anchorPoint = .zero
        buildLayers()
        applyItem(previous: nil)
    }

    func update(item newItem: TabItem) {
        isClosing = false // a tab the model still lists is not closing
        guard newItem != item else { return }
        let previous = item
        item = newItem
        applyItem(previous: previous)
    }

    // MARK: - Layers

    private func buildLayers() {
        let root = layer
        root.masksToBounds = false
        backgroundLayer.cornerCurve = .circular // Helium's tab: a circular-arc SkRRect, not a squircle
        iconLayer.contentsGravity = .resizeAspect
        titleLayer.font = titleFont
        // Keep a tab's distinguishing suffix visible when its chip is narrow (for example,
        // "Helper 1" and "Helper 2"). The hover marquee still expands to the full title.
        titleLayer.truncation = .middle
        for sublayer in [backgroundLayer, separatorLayer, iconLayer, titleLayer] {
            sublayer.actions = Self.noActions
            root.addSublayer(sublayer)
        }
        // Fills fade; geometry never implicitly animates.
        backgroundLayer.actions = ["backgroundColor": Self.fade, "shadowOpacity": Self.fade, "bounds": NSNull(), "position": NSNull()]
    }

    static let noActions: [String: any CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "zPosition": NSNull(), "contents": NSNull(), "opacity": NSNull(),
        "hidden": NSNull(), "string": NSNull(), "foregroundColor": NSNull(), "backgroundColor": NSNull(),
        "mask": NSNull(), "path": NSNull(), "strokeColor": NSNull(), "sublayers": NSNull(),
    ]

    /// Takes its duration from the `Motion.transaction` it runs in.
    static let fade = Motion.fadeAction

    private func applyItem(previous: TabItem?) {
        if previous?.title != item.title {
            measuredTitle = nil
            crossfadeRename(from: previous?.title)
            titleLayer.string = displayTitle
        }
        if previous?.indicator != item.indicator || previous?.busyStyle != item.busyStyle {
            updateSpinner()
        }
        if previous?.status != item.status || previous?.blockedKind != item.blockedKind { updateStatusGlyph() }
        if previous?.machineBadge != item.machineBadge { updateMachineBadge() }
        if previous?.themeBadge != item.themeBadge { updateThemeBadge() }
        if previous?.profileBadge != item.profileBadge { updateProfileBadge() }
        if previous?.presence != item.presence { updatePresenceDot() }
        if previous?.audio != item.audio { updateAudioBadge() }
        // Animated only for a tab that hibernates or wakes while it is in the strip.
        if (previous?.isDormant ?? false) != item.isDormant { updateHibernationRing(animated: previous != nil) }
        updateColors(animated: false)
        updateAccessibility()
        layoutLayers()
    }

    /// The name this Mac's inline rename just committed: its echo is direct manipulation (DESIGN.md
    /// 1.4 rule 4), already drawn by the editor, so it swaps without the crossfade. The next title
    /// change clears it.
    var directTitle: String?

    /// A rename (on another device, by an agent) crossfades the title in
    /// place on `crossfade` (plans/cmux-next/sync-ux/DESIGN.md 1.4 rule 6): the
    /// tab's width comes from the strip's layout, not from the text, so nothing
    /// else moves. A cell's first title and an untitled tab swap at once; the
    /// fade is at most `crossfade` under Reduce Motion and none when fades are off.
    private func crossfadeRename(from old: String?) {
        let direct = directTitle
        directTitle = nil
        guard let old, !old.isEmpty, !item.title.isEmpty, item.title != direct else { return }
        let seconds = Motion.tabs.duration(.crossfade)
        guard seconds > 0 else { return }
        let transition = Motion.crossfadeAction
        transition.duration = seconds
        transition.timingFunction = Motion.fadeCurve
        titleLayer.add(transition, forKey: "cmux.tabRename")
    }

    var displayTitle: String {
        item.title.isEmpty ? Strings.untitled : item.title
    }

    private func stateChanged(animated: Bool = true) {
        updateColors(animated: animated)
        updateAccessibility()
        // Hover shows or hides the x: its fade and the title's fade under
        // it animate (Motion `hover`); nothing moves.
        animatesCloseChange = animated
        layoutLayers()
        animatesCloseChange = false
        updateMarquee()
    }

    /// The pointer resting on a clipped title scrolls it after the hover
    /// delay; leaving stops it at once (TitleFade, Motion `MotionMarquee`).
    private func updateMarquee() {
        // Not while the parts follow a moving width (the title's frames are the path's); the rest
        // layout at the path's end starts it.
        if isHovered, allowsMarquee, !isLifted, visibility.showsTitle, innerPath == nil {
            titleFade.startMarquee()
        } else {
            titleFade.stopMarquee()
        }
    }

    private func updateLift() {
        themeScope.perform { backgroundLayer.shadowColor = Palette.shadow.cgColor }
        // The raised elevation step (PopupStyle.elevation2), not a darker drag shadow.
        let elevation = PopupStyle.elevation2
        backgroundLayer.shadowRadius = elevation.layerRadius
        backgroundLayer.shadowOffset = elevation.layerOffset(flipped: true)
        Motion.tabs.set(backgroundLayer, "shadowOpacity", to: Float(isLifted ? elevation.alpha : 0), fade: .lift)
        updateStacking()
        if isLifted { titleFade.stopMarquee(animated: false) }
        // The lifted fill reads as solid from the first frame, so nothing it
        // passes over (a group chip) shows through while it would ease in.
        updateColors(animated: !isLifted)
    }

    /// `showing` is whether the fill that changed shows: the tab's by
    /// default, the close button's for its own hover.
    func updateColors(animated: Bool, showing: Bool? = nil) {
        let token = animated ? ChromeHover.fade(showing: showing ?? (isLifted || fillsSelection || isMultiSelected || isHovered)) : nil
        // An instant change also ends a fill still easing in.
        if (token.map(Motion.tabs.duration) ?? 0) == 0 {
            for layer in [backgroundLayer, closeBackgroundLayer, audioBackgroundLayer, zoomBackgroundLayer].compactMap({ $0 }) { layer.removeAnimation(forKey: "backgroundColor") }
        }
        Motion.tabs.transaction(token) { applyColors() }
    }

    private func applyColors() {
        themeScope.perform {
            backgroundLayer.shadowColor = Palette.shadow.cgColor
            let multi = isMultiSelected && !isSelected
            let selection = isWindowMain || isLifted ? Palette.selectionFill
                : Palette.selectionFill.withAlphaComponent(Palette.selectionFill.alphaComponent * Self.backgroundWindowSelectionShare)
            let fill: NSColor? = fillsSelection ? selection : multi ? Palette.secondarySelectionFill : (isHovered && DesignSettings.shared.showsHoverFills ? Palette.hoverFill : nil)
            backgroundLayer.backgroundColor = fill?.cgColor
            if isLifted, let lift = Palette.windowBackground.blended(withFraction: 0.08, of: Palette.textPrimary) {
                // Keeps the tabs sliding under it quiet: solid when opaque, thicker glass when translucent.
                backgroundLayer.backgroundColor = WindowBackdrop.dragPreview(themeScope).dragLiftFill(lift).cgColor
            }
            // A hibernated tab keeps its title color (Chrome's discarded tabs do too); the ring marks it.
            let text = isSelected ? Palette.textPrimary : Palette.textSecondary
            hibernationRingLayer?.strokeColor = Self.hibernationRingColor.cgColor
            titleLayer.foregroundColor = text.cgColor
            machineLayer?.foregroundColor = item.machineBadgeColor.cgColor
            applyProfileDotColors()
            applyPresenceDotColor()
            applyAudioIcon()
            applyZoomIcon()
            let indicatorColors = StatusIndicatorLayer.Colors.current(loading: StatusIndicatorAppearance.shared.config.settings.color)
            spinnerLayer?.colors = indicatorColors
            statusGlyphLayer?.colors = indicatorColors
            iconLayer.contents = iconImage(tint: item.tint?.markColor ?? text)
            applySeparatorColor()
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
        case .none: return item.isUnread ? Palette.notificationBlue : nil
        }
    }

    // MARK: - Layout

    /// Rounds to the device pixel grid so icons, glyphs, and hairlines stay crisp.
    func pixel(_ value: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    /// Lays the parts out for the cell's width. While a strip move changes that width, the parts follow
    /// the moving bounds frame by frame on the render server (`retimeInner`); at rest they are placed.
    func layoutLayers() {
        let now = CACurrentMediaTime()
        let path = MotionPath(layer, "bounds.size", now: now)
        if path.isExact, let end = path.end, end > now + 0.001 {
            retimeInner(path, now: now, end: end)
        } else {
            let wasOnPath = innerPath != nil
            endInnerPath()
            layoutParts(slotWidth: bounds.width, onPath: false)
            if wasOnPath { updateMarquee() }
        }
    }

    /// The icon's leading x in a pill `pillWidth` wide for `form`: the content inset beside a title,
    /// centered alone, or centered in the room left of the x.
    private static func iconX(form: TabChromeVisibility, pillWidth: CGFloat, metrics m: TabStripMetrics) -> CGFloat {
        guard form.centersContent, form.showsIcon else { return m.contentLeadingInset }
        return form.showsClose
            ? max(m.contentLeadingInset / 2, (pillWidth - m.closeButtonSize - m.contentTrailingInset - m.iconSize) / 2)
            : (pillWidth - m.iconSize) / 2
    }

    /// Lays the parts out for a slot `slotWidth` wide. `onPath`: one sample of a moving width
    /// (`retimeInner`): no part is removed (it hides), nothing fades, and the title's geometry is
    /// recorded in `pathTitle` instead of applied. `form`: the path's form at this sample
    /// (`TabChromeVisibility.path`); nil lays out the rest form of the width.
    func layoutParts(slotWidth: CGFloat, onPath: Bool, form: TabChromeVisibility? = nil) {
        let slot = CGRect(x: 0, y: 0, width: slotWidth, height: layer.bounds.height)
        let m = metrics
        // The pill leaves the gap to the next tab at its trailing side (the
        // first pill starts on the border's line); content lays out in it.
        let bounds = m.pillFrame(slotWidth: slot.width, height: slot.height)
        visibility = closingVisibility ?? form ?? TabChromeVisibility.resolve(
            width: slot.width,
            isPinned: item.isPinned,
            isSelected: isSelected,
            isHovered: isHovered,
            isClosable: item.isClosable,
            style: style,
            metrics: m
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        backgroundLayer.frame = bounds
        layoutSeparator(slot: slot, pill: bounds)
        backgroundLayer.cornerRadius = m.cornerRadius

        let midY = bounds.height / 2
        let iconSide = m.iconSize
        var closeRect: CGRect?
        if let x = visibility.closeButtonOriginX(pillWidth: bounds.width, metrics: m) {
            let side = m.closeButtonSize
            closeRect = CGRect(x: pixel(x), y: pixel(midY - side / 2), width: side, height: side)
        }
        var iconX = Self.iconX(form: visibility, pillWidth: bounds.width, metrics: m)
        // Lawrence 2026-10-20: "i should not see layout shift here at all". Hover shows or hides the
        // x and the title; the favicon stays where the unhovered form put it while it fits before the x.
        if isHovered, visibility.showsIcon, let closeRect {
            let rest = TabChromeVisibility.resolve(
                width: slot.width, isPinned: item.isPinned, isSelected: isSelected, isHovered: false,
                isClosable: item.isClosable, style: style, metrics: m)
            let restX = Self.iconX(form: rest, pillWidth: bounds.width, metrics: m)
            if rest.showsIcon, pixel(restX) + iconSide <= closeRect.minX + 0.5 { iconX = restX }
        }
        let iconFrame = CGRect(x: pixel(iconX), y: pixel(midY - iconSide / 2), width: iconSide, height: iconSide)
        // Lawrence 2026-10-19: nothing but the favicon (or the tab's icon) draws in the leading
        // slot; the unread or status mark, the loading indicator and the other marks draw in the
        // trailing cluster (TabCell+TrailingMarks). A tab too narrow for its title has no
        // trailing room, so there they keep the icon's corner as before.
        let marksOnIcon = !visibility.showsTitle
        // Agent identity can be a custom image or symbol as well as a brand mark. Working keeps
        // that artwork under a small spinner badge; browser loading still replaces its favicon.
        let spinnerOnIcon = marksOnIcon && spinnerLayer != nil
        let spinnerBadgesMark = spinnerOnIcon && (item.indicator.isWorking || { if case .agentMark = item.icon { true } else { false } }())
        let showsIconArt = visibility.showsIcon && (!spinnerOnIcon || spinnerBadgesMark)
        // Bounds and position, not frame: a hibernated tab's icon is scaled (TabCell+HibernationRing).
        iconLayer.bounds = CGRect(origin: .zero, size: iconFrame.size)
        iconLayer.position = CGPoint(x: iconFrame.midX, y: iconFrame.midY)
        layoutHibernationRing(iconFrame: iconFrame, visible: showsIconArt)
        iconLayer.opacity = showsIconArt ? 1 : 0
        if marksOnIcon {
            layoutThemeBadge(frame: themeBadgeIconFrame(iconFrame: iconFrame), visible: visibility.showsIcon)
            if let spinnerLayer {
                if !isSpinnerExiting { spinnerLayer.layer.opacity = visibility.showsIcon ? 1 : 0 }
                if spinnerBadgesMark {
                    let side = pixel(iconFrame.width * 0.55)
                    spinnerLayer.frame = CGRect(x: pixel(iconFrame.maxX - side + Metrics.space1), y: pixel(iconFrame.maxY - side + Metrics.space1),
                                                width: side, height: side)
                } else {
                    spinnerLayer.frame = iconFrame.insetBy(dx: Metrics.space1, dy: Metrics.space1)
                }
            }
            layoutStateMark(iconFrame: iconFrame, visible: visibility.showsIcon, onPath: onPath)
        }

        if let closeRect {
            let appearing = !hasCloseLayers
            let (closeBackgroundLayer, closeGlyphLayer) = makeCloseLayers()
            closeBackgroundLayer.frame = closeRect
            closeBackgroundLayer.cornerRadius = m.closeCornerRadius
            let inset = (closeRect.width - m.closeGlyphSize) / 2
            let glyph = closeRect.insetBy(dx: inset, dy: inset)
            // The glyph's layer is its own rect, so a strip move animates where it is, not its path.
            closeGlyphLayer.frame = glyph
            closeGlyphLayer.path = Self.closeGlyphPath(in: CGRect(origin: .zero, size: glyph.size))
            if onPath {
                closeBackgroundLayer.opacity = 1
                closeGlyphLayer.opacity = 1
            } else if appearing, animatesCloseChange {
                for layer in [closeBackgroundLayer, closeGlyphLayer] as [CALayer] {
                    Motion.tabs.set(layer, "opacity", to: Float(1), fade: .hover, from: Float(0))
                }
            }
        } else if onPath {
            closeBackgroundLayer?.opacity = 0
            closeGlyphLayer?.opacity = 0
        } else {
            removeCloseLayers()
        }
        setCloseButtonRect(closeRect, pill: bounds)

        if visibility.showsTitle {
            // The title spans to the trailing inset while it fits. A clipped
            // title uses the visible area as its rest width so middle
            // truncation and the trailing fade share the same edge; the x or
            // badge still overlays the trailing inset without hiding its tail.
            let titleX = iconFrame.maxX + m.iconTitleSpacing
            let span = max(0, bounds.width - m.contentTrailingInset - titleX)
            let lineHeight = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
            titleLayer.opacity = 1
            let titleEnd = closeRect.map { $0.minX - m.titleCloseSpacing } ?? (bounds.width - m.contentTrailingInset)
            let visibleEnd = layoutTrailingMarks(titleX: titleX, titleEnd: titleEnd, midY: midY, onPath: onPath)
            // The marquee fades glyphs out across the icon-title gap.
            let textWidth = titleWidth()
            let visibleWidth = visibleEnd - titleX
            let isMiddleTruncated = textWidth > visibleWidth + 0.5
            let restWidth = isMiddleTruncated ? visibleWidth : span
            let geometry = TitleFadeGeometry(
                textWidth: textWidth, span: span, visibleWidth: visibleWidth,
                leadingPadding: m.iconTitleSpacing, trailingPadding: 0,
                // Keep the existing trailing fade for every clipped title;
                // the rest width above keeps the suffix inside that visible
                // area before the close button or badge.
                fadeWidth: m.titleFadeWidth,
                restWidth: restWidth
            )
            let frame = CGRect(x: pixel(titleX), y: pixel(midY - lineHeight / 2), width: span, height: lineHeight)
            if onPath {
                pathTitle = TitleFade.Sample(geometry: geometry, frame: frame)
            } else {
                titleFade.apply(geometry, frame: frame, animated: animatesCloseChange)
            }
        } else {
            titleLayer.opacity = 0
            for badge in [machineLayer, profileLayer, presenceLayer, audioLayer, audioBackgroundLayer, zoomLayer, zoomBackgroundLayer] { badge?.opacity = 0 }
            if onPath {
                pathTitle = nil
            } else {
                titleFade.stopMarquee(animated: false)
                titleLayer.mask = nil
            }
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
