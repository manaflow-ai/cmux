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
/// like AppKit's own tooltip. Its view is ``TooltipContentView`` (the text, then the shortcut's
/// keycap; ``TooltipMetrics``) on a small rounded surface of the shared overlay glass
/// (`Glass.makeOverlayPanel`, as the hover cards'; Leo 2026-10-21: "WHERE IS THE GLASS EVERYWHERE, all
/// these hover tooltips and hover previews"): the Liquid Glass in the hovered view's theme tint, the
/// themed blur before macOS 26, the opaque popup surface only under Reduce Transparency. Over the
/// glass and under the content lies the legibility tint (`TooltipSurface.tint`), so the text keeps
/// 4.5:1 over any backdrop the glass shows; it and the content follow the panel's theme scope while
/// shown. A small tight shadow sits under it, inset in the window by `margin` so the shadow has room.
/// scripts/cmux-next/check-overlay-glass.py fails a tooltip or hover card window that is not this glass.
///
/// It shows and goes in one frame, as the pages' tooltip does (Leo, 2026-11-11: "the fade-in, the
/// fade-out, is just so stupid... It's just sluggish."; Lawrence 2026-11-20: one tooltip, consistent
/// everywhere): the hover delay and the warm group's hand-off are the motion (`TooltipPresenter`).
final class TooltipPanel: NSPanel {
    static var maxWidth: CGFloat { TooltipMetrics.maxWidth * TooltipContentView.scale }
    static var radius: CGFloat { TooltipMetrics.radius * TooltipContentView.scale }
    /// Room around the surface for its shadow.
    static let margin: CGFloat = 3

    /// The text and the keycap.
    let content = TooltipContentView()
    /// The text (tests).
    var text: ChromeLabel { content.text }
    /// The surface: it carries the shadow.
    let surface = NSView()
    /// The shared overlay glass (its material follows Reduce Transparency); the content sits in its
    /// `contentView`.
    let glass: OverlaySurfaceView
    /// The legibility tint over the glass, under the content (`TooltipStyle.tint`): the glass's own
    /// theme tint is too light for the ink over a pure white or black backdrop (Codex review of
    /// #23970). Clear on the opaque material (Reduce Transparency), already that surface. Its theme
    /// hook (a theme change of the panel's scope, a Reduce Transparency switch) recolors it and the
    /// content while the tooltip shows.
    let legibility = ThemeChangeView()
    /// The scope the glass draws in: the hovered view's, at full strength.
    private weak var adoptedScope: ThemeScope?

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
        configureSurfaceShadow()
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.autoresizingMask = [.width, .height]
        surface.addSubview(glass)
        legibility.wantsLayer = true
        legibility.translatesAutoresizingMaskIntoConstraints = true
        // Sized by `show` alone: the Liquid Glass lays its contentView out by constraints, later, and
        // a mask would add that growth on top of the frame `show` set (fleet run: twice the surface).
        legibility.autoresizingMask = []
        legibility.layer?.cornerCurve = .continuous
        legibility.layer?.masksToBounds = true
        legibility.onThemeChange = { [weak self] in self?.applyColors() }
        glass.contentView.addSubview(legibility)
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = []
        glass.contentView.addSubview(content)
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
        // The panel lives for the process: the corner rule in effect now (density, layout.paneCornerRadius,
        // layout.cornerPadding) rounds this tooltip, as it does its shadow below.
        glass.cornerRadius = Self.radius
        legibility.layer?.cornerRadius = Self.radius
        glass.refreshMaterial()
        glass.applyTheme()
        content.set(text: value, shortcut: shortcut)
        applyColors()
        let size = content.fittingSurfaceSize(maxWidth: Self.maxWidth)
        let radius = Self.radius
        glass.cornerRadius = radius
        legibility.layer?.cornerRadius = radius
        setContentSize(NSSize(width: size.width + Self.margin * 2, height: size.height + Self.margin * 2))
        surface.frame = NSRect(x: Self.margin, y: Self.margin, width: size.width, height: size.height)
        glass.frame = surface.bounds
        legibility.frame = surface.bounds
        content.frame = surface.bounds
        content.layoutSubtreeIfNeeded()
        surface.layer?.shadowPath = CGPath(roundedRect: surface.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        configureSurfaceShadow()
    }

    /// Recolors the content and the legibility tint in the panel's theme scope (the adopted one):
    /// on show, and from the tint's theme hook while shown.
    private func applyColors() {
        let style = legibility.performWithTheme { TooltipStyle.current() }
        content.paint(ink: style.ink, hint: style.hint)
        legibility.layer?.backgroundColor = glass.material == .opaque ? NSColor.clear.cgColor : style.tint.cgColor
    }

    /// Puts it on screen, in one frame.
    func present() {
        surface.layer?.removeAllAnimations()
        if let layer = surface.layer { Motion.withoutAnimation { layer.opacity = 1 } }
        orderFrontRegardless()
    }

    /// Takes it off screen at once: the pointer left, a click, a key, a scroll or the app going inactive.
    func hideNow() {
        orderOut(nil)
    }
}
