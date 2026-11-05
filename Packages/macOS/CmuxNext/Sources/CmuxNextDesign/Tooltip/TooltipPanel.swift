import AppKit
import CmuxNextCompat

/// The tooltip's ink and legibility tint, read in the panel's theme scope.
struct TooltipStyle {
    /// `TooltipSurface.ink`: the theme's primary text, unless no translucent tint reads under it.
    var ink: NSColor
    var hint: NSColor
    /// `TooltipSurface.tint`: the popup surface at the least alpha that keeps `ink` at 4.5:1 over
    /// the tint laid on pure black and on pure white, at most `maximumTintAlpha`. Always
    /// translucent glass, never solid.
    var tint: NSColor

    /// The scope's colors, frozen (the labels draw them as they are). theme-scoped
    @MainActor static func current() -> TooltipStyle {
        func frozen(_ color: NSColor) -> NSColor { color.usingColorSpace(.sRGB) ?? color }
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        let surface = TooltipSurface(tokens, lift: ChromeTunables.opaqueOverlayLift.value)
        return TooltipStyle(ink: frozen(surface.ink.nsColor), hint: frozen(Palette.textSecondary), tint: surface.tint.nsColor)
    }
}

/// The one tooltip window: borderless, never key, ignoring the mouse, above page windows and panels
/// like AppKit's own tooltip. Its view is the text, then the shortcut hint, on a small rounded
/// surface of the shared overlay glass (`Glass.makeOverlayPanel`, as the hover cards'; Leo
/// 2026-10-21: "WHERE IS THE GLASS EVERYWHERE, all these hover tooltips and hover previews"): the
/// Liquid Glass in the hovered view's theme tint, the themed blur before macOS 26, the opaque popup
/// surface only under Reduce Transparency. Over the glass and under the labels lies the legibility
/// tint (`TooltipSurface.tint`), so the text keeps 4.5:1 over any backdrop the glass shows; it and
/// the labels follow the panel's theme scope while shown. A small tight shadow sits under it, inset in the window
/// by `margin` so the shadow has room. scripts/cmux-next/check-overlay-glass.py fails a tooltip or
/// hover card window that is not this glass.
///
/// It fades in (`MotionFade.fadeIn`) rising `rise` points, unless a tooltip of the warm group just
/// showed (then it is there at once), and fades out (`fadeOut`, quicker). Reduce Motion keeps the
/// fade and drops the rise.
final class TooltipPanel: NSPanel {
    static let maxWidth: CGFloat = 320
    static let padding = NSSize(width: 8, height: 4)
    static let radius: CGFloat = SurfaceRole.tooltip.cornerRadius ?? 5
    /// Room around the surface for its shadow.
    static let margin: CGFloat = 3
    /// How far the surface rises as it fades in.
    static let rise: CGFloat = 2

    let text = ChromeLabel(wrappingLabelWithString: "")
    let hint = ChromeLabel(labelWithString: "")
    /// The surface: it carries the shadow, and the fade and the rise run on its layer.
    let surface = NSView()
    /// The shared overlay glass (its material follows Reduce Transparency); the labels sit in its
    /// `contentView`.
    let glass: OverlaySurfaceView
    /// The legibility tint over the glass, under the labels (`TooltipStyle.tint`): the glass's own
    /// theme tint is too light for the ink over a pure white or black backdrop (Codex review of
    /// #23970). Clear on the opaque material (Reduce Transparency), already that surface. Its theme
    /// hook (a theme change of the panel's scope, a Reduce Transparency switch) recolors it and the
    /// labels while the tooltip shows.
    let legibility = ThemeChangeView()
    /// The scope the glass draws in: the hovered view's, at full strength.
    private weak var adoptedScope: ThemeScope?
    /// Bumped by every show and fade-out, so a finished fade-out of an earlier one orders nothing out.
    private var generation = 0
    /// Fading out: still on screen, already gone for the presenter.
    private(set) var isFadingOut = false

    init() {
        glass = Glass.makeSurface(.tooltip, cornerRadius: Self.radius, interactive: false)
        // The glass is its clear window's whole content: before macOS 26 its blur samples what is
        // behind the window (the page, a terminal), as its Liquid Glass refracts it.
        glass.samplesBehindWindow = true
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
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.autoresizingMask = [.width, .height]
        surface.addSubview(glass)
        legibility.wantsLayer = true
        legibility.translatesAutoresizingMaskIntoConstraints = true
        // Sized by `show` alone: the Liquid Glass lays its contentView out by constraints, later, and
        // a mask would add that growth on top of the frame `show` set (fleet run: twice the surface).
        legibility.autoresizingMask = []
        legibility.layer?.cornerRadius = Self.radius
        legibility.layer?.cornerCurve = .continuous
        legibility.layer?.masksToBounds = true
        legibility.onThemeChange = { [weak self] in self?.applyColors() }
        glass.contentView.addSubview(legibility)
        for label in [text, hint] {
            label.font = Typography.caption
            label.isSelectable = false
            label.drawsBackground = false
            label.translatesAutoresizingMaskIntoConstraints = true
            glass.contentView.addSubview(label)
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

    /// Lays out `text` and `shortcut` and sizes the window to them, on the glass of `scope` (the
    /// hovered view's), in its colors.
    func show(text value: String, shortcut: String?, scope: ThemeScope, appearance: NSAppearance) {
        if adoptedScope !== scope {
            scope.adopt(self)
            adoptedScope = scope
        }
        self.appearance = appearance
        glass.refreshMaterial()
        glass.applyTheme()
        applyColors()
        text.stringValue = value
        hint.stringValue = shortcut ?? ""
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
        glass.frame = surface.bounds
        legibility.frame = surface.bounds
        surface.layer?.shadowPath = CGPath(roundedRect: surface.bounds, cornerWidth: Self.radius, cornerHeight: Self.radius,
                                           transform: nil)
        configureSurfaceShadow()
    }

    /// Recolors the labels and the legibility tint in the panel's theme scope (the adopted one):
    /// on show, and from the tint's theme hook while shown.
    private func applyColors() {
        let style = legibility.performWithTheme { TooltipStyle.current() }
        text.textColor = style.ink
        hint.textColor = style.hint
        legibility.layer?.backgroundColor = glass.material == .opaque ? NSColor.clear.cgColor : style.tint.cgColor
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
        CATransaction.setMainCompletion { [weak self] in self?.fadedOut(fading) }
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
