import AppKit

/// The tooltip's colors, read in the hovered view's theme scope.
struct TooltipStyle {
    /// The surface fill: the frosted tint (`TooltipSurface.tint`), or the
    /// opaque popup surface under Reduce Transparency.
    var fill: NSColor
    var border: NSColor
    var ink: NSColor
    var hint: NSColor
    /// Frosted glass under the fill; false: the fill alone, opaque.
    var frosted: Bool

    /// The scope's colors, frozen (the panel itself sits in no scope). theme-scoped
    @MainActor static func current(reduceTransparency: Bool = ReduceTransparency.shared.isEnabled) -> TooltipStyle {
        func frozen(_ color: NSColor) -> NSColor { color.usingColorSpace(.sRGB) ?? color }
        let opaque = frozen(Palette.popupSurface)
        // Outside a theme scope there are no tokens to check the tint against: the opaque surface.
        let tint = ThemeContext.active.map { TooltipSurface($0, lift: ChromeTunables.opaqueOverlayLift.value).tint.nsColor }
        let frosted = !reduceTransparency && tint != nil
        return TooltipStyle(fill: frosted ? frozen(tint ?? opaque) : opaque, border: frozen(Palette.separator),
                            ink: frozen(Palette.textPrimary), hint: frozen(Palette.textSecondary), frosted: frosted)
    }
}

/// The one tooltip window: borderless, never key, ignoring the mouse, above page windows and panels
/// like AppKit's own tooltip. Its view is the text, then the shortcut hint, on a small rounded
/// surface of frosted glass (`TooltipSurface`): the blur, the tint, a one-device-pixel rim and a
/// small tight shadow, inset in the window by `margin` so the shadow has room.
///
/// It fades in (`MotionFade.fadeIn`) rising `rise` points, unless a tooltip of the warm group just
/// showed (then it is there at once), and fades out (`fadeOut`, quicker). Reduce Motion keeps the
/// fade and drops the rise.
final class TooltipPanel: NSPanel {
    static let maxWidth: CGFloat = 320
    static let padding = NSSize(width: 8, height: 4)
    static let radius: CGFloat = 5
    /// Room around the surface for its shadow.
    static let margin: CGFloat = 3
    /// How far the surface rises as it fades in.
    static let rise: CGFloat = 2

    let text = ChromeLabel(wrappingLabelWithString: "")
    let hint = ChromeLabel(labelWithString: "")
    /// The surface: it carries the shadow, and the fade and the rise run on its layer.
    let surface = NSView()
    /// The frosted glass under the tint (hidden under Reduce Transparency).
    let blur = NSVisualEffectView()
    /// The tint, the rim and the labels, over the blur.
    let tint = NSView()
    /// Bumped by every show and fade-out, so a finished fade-out of an earlier one orders nothing out.
    private var generation = 0
    /// Fading out: still on screen, already gone for the presenter.
    private(set) var isFadingOut = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        // The surface draws its own small shadow; the window's is a large one.
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = !WindowPlacement.noActivate
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        level = .popUpMenu
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle, .canJoinAllSpaces]
        let root = NSView()
        root.wantsLayer = true
        surface.wantsLayer = true
        surface.layer?.masksToBounds = false
        surface.layer?.shadowColor = NSColor.black.cgColor
        surface.layer?.shadowOpacity = Float(TooltipSurface.shadow.alpha)
        surface.layer?.shadowRadius = TooltipSurface.shadow.layerRadius
        surface.layer?.shadowOffset = TooltipSurface.shadow.layerOffset()
        blur.material = .toolTip
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        tint.wantsLayer = true
        for view in [blur, tint] {
            view.autoresizingMask = [.width, .height]
            view.layer?.cornerRadius = Self.radius
            view.layer?.cornerCurve = .continuous
            view.layer?.masksToBounds = true
            surface.addSubview(view)
        }
        for label in [text, hint] {
            label.font = Typography.caption
            label.isSelectable = false
            label.drawsBackground = false
            label.translatesAutoresizingMaskIntoConstraints = true
            tint.addSubview(label)
        }
        text.maximumNumberOfLines = 0
        hint.alignment = .right
        root.addSubview(surface)
        contentView = root
        setAccessibilityElement(false)
    }

    /// AppKit may recreate an NSView-backed layer when the view enters a
    /// window. Reapply the surface shadow at presentation time so the panel
    /// keeps its elevation contract after that replacement.
    private func configureSurfaceShadow() {
        guard let layer = surface.layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = Float(TooltipSurface.shadow.alpha)
        layer.shadowRadius = TooltipSurface.shadow.layerRadius
        layer.shadowOffset = TooltipSurface.shadow.layerOffset()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The surface's size: the window's, less the shadow's margin.
    var surfaceSize: NSSize {
        NSSize(width: frame.width - Self.margin * 2, height: frame.height - Self.margin * 2)
    }

    /// Lays out `text` and `shortcut` in `style` and sizes the window to them; `scale` is the
    /// backing scale of the screen it shows on (the rim is one of its pixels).
    func show(text value: String, shortcut: String?, style: TooltipStyle, appearance: NSAppearance, scale: CGFloat) {
        self.appearance = appearance
        blur.isHidden = !style.frosted
        tint.layer?.backgroundColor = style.fill.cgColor
        tint.layer?.borderColor = style.border.cgColor
        // One device pixel (`--cmux-hairline` in pages).
        tint.layer?.borderWidth = 1 / max(scale, 1)
        text.stringValue = value
        text.textColor = style.ink
        hint.stringValue = shortcut ?? ""
        hint.textColor = style.hint
        hint.isHidden = shortcut?.isEmpty ?? true
        let pad = Self.padding
        let hintSize = hint.isHidden ? .zero : hint.fittingSize
        let hintRoom = hint.isHidden ? 0 : hintSize.width + Metrics.space2
        text.preferredMaxLayoutWidth = Self.maxWidth - pad.width * 2 - hintRoom
        let textSize = text.fittingSize
        let width = ceil(textSize.width + hintRoom + pad.width * 2)
        let height = ceil(max(textSize.height, hintSize.height) + pad.height * 2)
        text.frame = NSRect(x: pad.width, y: pad.height, width: ceil(textSize.width), height: ceil(textSize.height))
        hint.frame = NSRect(x: width - pad.width - ceil(hintSize.width), y: height - pad.height - ceil(hintSize.height),
                            width: ceil(hintSize.width), height: ceil(hintSize.height))
        setContentSize(NSSize(width: width + Self.margin * 2, height: height + Self.margin * 2))
        surface.frame = NSRect(x: Self.margin, y: Self.margin, width: width, height: height)
        surface.layer?.shadowPath = CGPath(roundedRect: surface.bounds, cornerWidth: Self.radius, cornerHeight: Self.radius,
                                           transform: nil)
        configureSurfaceShadow()
    }

    /// Puts it on screen: fading in and rising when `fade`, else at once (a warm neighbor's, or new text).
    func present(fade: Bool) {
        // Already up (new text, a warm swap): it stays as it is, a fade in under way included.
        if !fade, isVisible, !isFadingOut {
            orderFrontRegardless()
            return
        }
        generation += 1
        isFadingOut = false
        guard let layer = surface.layer else {
            orderFrontRegardless()
            return
        }
        if fade, !isVisible {
            Motion.hoverCards.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
            Motion.hoverCards.set(layer, "transform.translation.y", to: CGFloat(0), movementFade: .fadeIn, from: -Self.rise)
        } else {
            layer.removeAllAnimations()
            Motion.withoutAnimation { layer.opacity = 1 }
        }
        orderFrontRegardless()
    }

    /// Takes it off screen, fading out first (`fadeOut`, quicker than the fade in).
    func fadeOut() {
        guard isVisible, !isFadingOut else { return }
        generation += 1
        let fading = generation
        guard let layer = surface.layer, Motion.hoverCards.duration(.fadeOut) > 0 else {
            orderOut(nil)
            return
        }
        isFadingOut = true
        layer.removeAnimation(forKey: "transform.translation.y")
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.fadedOut(fading) } // main-proof: CATransaction.h: the completion block is called on the main thread
        }
        Motion.hoverCards.set(layer, "opacity", to: Float(0), fade: .fadeOut, from: layer.presentation()?.opacity ?? layer.opacity)
        CATransaction.commit()
    }

    /// Takes it off screen at once: a click, a key, a scroll or the app going inactive (as AppKit's
    /// tooltip, it does not linger over the menu a click opens or over moving content).
    func hideNow() {
        generation += 1
        isFadingOut = false
        surface.layer?.removeAllAnimations()
        if let layer = surface.layer { Motion.withoutAnimation { layer.opacity = 1 } }
        orderOut(nil)
    }

    private func fadedOut(_ fading: Int) {
        guard fading == generation else { return }
        isFadingOut = false
        orderOut(nil)
    }
}
