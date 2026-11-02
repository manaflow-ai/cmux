public import AppKit
import CoreImage
import CmuxNextCompat
public import CmuxNextDesignTokens

/// The one material behind a window's content (``WindowMaterial``) and the
/// one theme tint, as the window root's bottom subview.
///
/// It hosts at most one material view: a Liquid Glass `GlassPanelView` for
/// ``WindowMaterial/glass(_:)``, and none for ``WindowMaterial/frosted``
/// or ``WindowMaterial/translucent`` (only the tint; the window's CGS
/// blur radius frosts what shows through) or ``WindowMaterial/opaque``,
/// where the root paints the solid background itself. Glass carries the
/// tint itself (its `tintColor`, as Ghostty.app tints its glass) and the
/// tint view stays hidden: untinted glass draws its own dark material, and
/// a second tint over it dimmed the desktop twice. The glass keeps its key look when the window
/// resigns key (``ActiveLookGlassEffectView``), so switching apps changes nothing on the window
/// background. Neither the material nor the tint draws a border.
/// The owner decides the backdrop (including Reduce Transparency) and calls
/// ``apply(_:tint:)`` on every theme change.
///
/// ```swift
/// let backdrop = WindowMaterialView()
/// backdrop.apply(WindowBackdrop(tokens), tint: Palette.windowBackground)
/// ```
public final class WindowMaterialView: NSView {
    /// The material shown now.
    public private(set) var material: WindowMaterial = .opaque
    /// The view drawing ``material``; nil while opaque.
    public private(set) var materialView: NSView?
    private let tintView = NSView()
    private let glassTint = GlassTintBlend()
    /// The inactive wash (`appearance.inactiveWindowDim`, off by default) sits under the in-app
    /// art, so a dim never hides the person's own background.
    let inactiveTintView = NSView()
    /// The inactive wash's alpha once its fade ends (`updateInactiveTint`).
    private var inactiveTintTarget: CGFloat = 0
    /// The theme tint at full alpha, the inactive wash's color; nil while opaque.
    private var washColor: CGColor?
    /// Bumped by each wash fade: only the latest fade-out's completion hides the view (a
    /// replaced animation completes too).
    private var inactiveTintFade = 0
    /// The window's key tracker; it says whether the window looks inactive and calls
    /// ``updateInactiveTint()`` when that flips.
    private var keyFamily: WindowKeyFamily?
    /// Posted when `appearance.inactiveWindowDim` changes (``DesignSettings/inactiveWindowDim``).
    public static let inactiveDimDidChange = Notification.Name("WindowMaterialView.inactiveDimDidChange")
    /// The keyboard left the window's family: another app, or a window that is not this one, its
    /// child (a Chromium page window, popup, palette) or its sheet. Only then does the window look
    /// inactive (Leo 2026-10-21: "on itself? that should never happen"); a window whose family
    /// never held the keyboard (opening, tests, snapshots) shows the glass alone.
    private var resignedKey: Bool { keyFamily?.isInactive ?? false }
    /// The art layer (tests read what it shows): the whole image aspect-filled over the whole
    /// view, centered, like a macOS wallpaper. Its frame autoresizes with the window, so nothing
    /// is computed per size and nothing jumps while resizing.
    let artView = NSView()
    /// The art layer's opacity (`WindowBackdrop.artOpacity`), the end of its fade-in.
    private(set) var artOpacity: Float = 1
    private var loadedSelection: BackdropSelection?
    private var loadedArt: BackdropArt?
    private var loadedTexture: BackdropTexture?
    /// The appearance the art loaded for: a dynamic Apple picture or shipped video has one of each.
    private var loadedDark = false
    /// The desktop's ``DesktopWallpaperWatch/generation`` the Desktop Wallpaper art loaded for.
    private var loadedDesktopGeneration = 0
    /// The last `apply`, run again when the appearance flips under art that follows it.
    private var applied: (backdrop: WindowBackdrop, tint: NSColor)?
    /// A video wallpaper over the art (its poster), playing while seen (``BackdropVideoView``).
    public let videoView: BackdropVideoView
    private(set) var artImage: NSImage?
    /// A video wallpaper plays over the art (pages get no still of it, `glassSource`).
    private(set) var showsVideo = false
    /// The web views lensing this backdrop, told when what they draw changes (`glassSource`).
    let glassFeeds = NSHashTable<GlassBackdropFeed>.weakObjects()
    private let images: BackdropImageStore
    /// The app's ``ActiveLookScope``: its glass keeps the key look while the window is not key
    /// (nil: the glass follows the key state). A child window takes its owner's
    /// (`NSWindow.backdropActiveLook`).
    public let activeLook: ActiveLookScope?
    /// The desktop picture (the image store's): its color leans the tint
    /// (`appearance.wallpaperTint`), and the Desktop Wallpaper art reloads when it changes.
    private var wallpaper: DesktopWallpaperWatch { images.desktop }
    /// Loads the art the last `apply` asked for when it was not decoded yet; a later `apply`
    /// that needs other art cancels and replaces it. Tests await its `value` to see the art the
    /// load shows.
    private(set) var artLoad: Task<Void, Never>?
    /// The solid sheet and Reduce Transparency must never expose art.
    private(set) var hidesArt = false
    /// The blur on the art now (``WindowBackdrop/artBlurRadius``).
    private(set) var artBlurRadius = 0

    /// Creates an opaque backdrop (no material view, no tint).
    ///
    /// - Parameter frameRect: The initial frame.
    override public convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, images: .shared)
    }

    /// Creates an opaque backdrop whose art comes from `images`.
    ///
    /// - Parameter frameRect: The initial frame.
    /// - Parameter images: Where decoded backdrop images are shared.
    /// - Parameter videos: Where video wallpapers' players are shared.
    /// - Parameter activeLook: The app's ``ActiveLookScope`` (made once by `AppServices`) for a
    ///   window backdrop; nil for one whose glass follows the key state.
    public init(frame frameRect: NSRect, images: BackdropImageStore, videos: BackdropVideoPlayers = .shared,
                activeLook: ActiveLookScope? = nil) {
        self.images = images
        self.activeLook = activeLook
        videoView = BackdropVideoView(frame: frameRect, players: videos)
        super.init(frame: frameRect)
        artView.wantsLayer = true
        artView.frame = bounds
        artView.autoresizingMask = [.width, .height]
        artView.layer?.contentsGravity = .resizeAspectFill
        artView.layer?.masksToBounds = true
        artView.isHidden = true
        addSubview(artView)
        videoView.frame = bounds
        videoView.autoresizingMask = [.width, .height]
        addSubview(videoView)
        glassTint.overlay.frame = bounds
        glassTint.overlay.autoresizingMask = [.width, .height]
        addSubview(glassTint.overlay)
        tintView.wantsLayer = true
        tintView.frame = bounds
        tintView.autoresizingMask = [.width, .height]
        tintView.isHidden = true
        addSubview(tintView)
        inactiveTintView.wantsLayer = true
        inactiveTintView.frame = bounds
        inactiveTintView.autoresizingMask = [.width, .height]
        inactiveTintView.isHidden = true
        inactiveTintView.layer?.opacity = 0
        // The wash is a desktop shield, not a veil over the person's background. Keep it below
        // art (and the glass/material stack above art) so losing focus cannot dim or hide that art.
        addSubview(inactiveTintView, positioned: .below, relativeTo: artView)
        setAccessibilityElement(false)
        images.desktop.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The one theme tint at the backdrop's opacity: the glass view's own
    /// tint for glass, otherwise the color laid over the desktop; nil while
    /// opaque.
    public var tintColor: CGColor? {
        if let glass = materialView as? GlassPanelView { return glass.tintColor?.cgColor }
        return tintView.isHidden ? nil : tintView.layer?.backgroundColor
    }

    /// The layer of the tint over the desktop while it shows (`debug.themes`).
    var shownTintLayer: CALayer? { tintView.isHidden ? nil : tintView.layer }
    /// Liquid Glass's own tint (its end color) and the overlay that blends from the old one while
    /// it shows (`debug.themes`).
    var glassTintColor: CGColor? { (materialView as? GlassPanelView)?.tintColor?.cgColor }
    var shownGlassBlendLayer: CALayer? { glassTint.overlay.isHidden ? nil : glassTint.overlay.layer }

    /// The theme tint laid over the window while it is not key, at full alpha: only
    /// `appearance.inactiveWindowDim`, 0 by default. Its resting alpha: where its fade ends.
    var inactiveTintAlpha: CGFloat { inactiveTintTarget }

    /// The wash over a window that is not key: none while it is key or opaque, else `dim`
    /// (`appearance.inactiveWindowDim`, 0 by default: the same look in front and behind). Glass
    /// needs no wash of its own: it keeps its key look (``ActiveLookGlassEffectView``), and a wash
    /// over it was the frost Leo saw on every app switch (2026-10-26: "i didnt want any glass.
    /// you're frosting the app's background which is pointless?").
    static func inactiveTintAlpha(material: WindowMaterial, isKeyWindow: Bool, dim: CGFloat) -> CGFloat {
        guard material != .opaque, !isKeyWindow else { return 0 }
        return min(max(dim, 0), 1)
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The app's appearance has flipped by now; macOS's own notice can come before it does.
        wallpaper.appearanceDidChange()
        // A dynamic Apple picture or a shipped video has a light and a dark file.
        if let applied, applied.backdrop.selection?.followsAppearance == true { apply(applied.backdrop, tint: applied.tint) }
    }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        keyFamily?.remove(self)
        keyFamily = nil
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            keyFamily = WindowKeyFamily.of(window)
            keyFamily?.add(self)
        }
        updateInactiveTint()
    }

    /// Whether `key` (the key window, nil when none) is `window` or a window it owns, through
    /// `owner` (a window's parent or sheet parent).
    static func family<W: AnyObject>(of window: W, holds key: W?, owner: (W) -> W?) -> Bool {
        var next = key
        // Window chains are a few levels deep; the bound guards a cycle.
        for _ in 0..<32 {
            guard let current = next else { return false }
            if current === window { return true }
            next = owner(current)
        }
        return false
    }

    /// A window looks inactive only once its family held the keyboard and then lost it to another
    /// app or another window; its own page windows, popups and sheets never make it look inactive.
    static func looksInactive(appActive: Bool, familyHoldsKey: Bool, familyHeldKey: Bool) -> Bool {
        guard familyHeldKey || (appActive && familyHoldsKey) else { return false }
        return !(appActive && familyHoldsKey)
    }

    /// Shows the wash for the window's key state now. `fades` eases it in or out (`scrim`), for a
    /// setting or theme change. A key change passes false: the wash then lands in the same
    /// transaction as AppKit's own key-state redraw (the traffic lights), so a dim set with
    /// `appearance.inactiveWindowDim` lands as one change, not a second step after it (Leo
    /// 2026-10-25: "it frosts the glass before the background").
    func updateInactiveTint(fades: Bool = true) {
        let alpha = washColor == nil ? 0 : Self.inactiveTintAlpha(material: material, isKeyWindow: !resignedKey,
                                                                   dim: CGFloat(DesignSettings.shared.inactiveWindowDim))
        let wash = alpha > 0 ? washColor : nil
        guard let layer = inactiveTintView.layer else { return }
        let previous = inactiveTintTarget
        inactiveTintTarget = alpha
        // A window not on screen, or a key change, applies at once.
        let eases = fades && window?.isVisible == true
        // Visible now, mid-fade included (the model opacity of a fading-out wash is already 0).
        let showing = !inactiveTintView.isHidden
        // The wash's color: a tint change while it shows blends like the glass under it. A wash
        // fading out keeps its color until it is gone.
        if let wash, layer.backgroundColor != wash {
            if layer.backgroundColor != nil, showing, eases {
                ColorTransition.current.animate(layer, to: wash)
            } else {
                layer.removeAnimation(forKey: ColorTransition.layerKey)
                layer.backgroundColor = wash
            }
        }
        guard eases else {
            inactiveTintFade += 1
            layer.removeAnimation(forKey: "opacity")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = Float(alpha)
            CATransaction.commit()
            inactiveTintView.isHidden = alpha == 0
            return
        }
        // Showing or hiding the wash for a setting or theme change eases (`scrim`): a whole-window
        // dim in one frame reads as a flash (Leo 2026-10-20).
        // Same target: a fade under way runs on (a theme apply mid-fade does not cut it short).
        guard alpha != previous || (alpha > 0 && !showing) else { return }
        guard alpha > 0 || showing else { return }
        inactiveTintFade += 1
        let fade = inactiveTintFade
        inactiveTintView.isHidden = false
        CATransaction.begin()
        CATransaction.setMainCompletion { [weak self] in
            guard let self, self.inactiveTintFade == fade, self.inactiveTintTarget == 0 else { return }
            self.inactiveTintView.isHidden = true
        }
        // From what shows now (a reversal mid-fade continues from there), or from 0 when hidden.
        Motion.overlays.set(layer, "opacity", to: Float(alpha), fade: .scrim, from: showing ? nil : Float(0))
        CATransaction.commit()
    }

    /// Decoration only: clicks reach the views above or the window.
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `backdrop`'s material with `tint` at
    /// ``WindowBackdrop/tintOpacity`` (over it, or for glass as its tint). The material view is replaced only
    /// when the material changes.
    ///
    /// - Parameter backdrop: The window's backdrop.
    /// - Parameter tint: The theme background; its alpha is replaced by
    ///   the backdrop's tint opacity.
    public func apply(_ backdrop: WindowBackdrop, tint: NSColor) {
        hidesArt = backdrop.isOpaque
        applied = (backdrop, tint)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let shown = backdrop.selection ?? backdrop.art.map(BackdropSelection.art)
        let flipped = shown?.followsAppearance == true && loadedDark != dark
        // The desktop moved on (a new picture, a Space with its own): the Desktop Wallpaper reloads.
        let desktopMoved = shown == .desktop && loadedDesktopGeneration != wallpaper.generation
        if loadedSelection != backdrop.selection || loadedArt != backdrop.art || loadedTexture != backdrop.texture || flipped || desktopMoved {
            loadedSelection = backdrop.selection
            loadedArt = backdrop.art
            loadedTexture = backdrop.texture
            loadedDark = dark
            loadedDesktopGeneration = wallpaper.generation
            if shown == .desktop { images.forgetDesktopPicture(olderThan: wallpaper.generation) }
            artLoad?.cancel()
            artLoad = nil
            let texture = backdrop.texture
            // Decoded art shows at once. Otherwise an earlier launch's snapshot shows in this
            // first frame, and the full image replaces it in place; without one the window shows
            // the theme's colors until the art, decoded off the main actor, fades in.
            let ready = shown.flatMap { images.cached($0, texture: texture, dark: dark) }
            showArt(ready ?? (hidesArt ? nil : shown.flatMap { images.preview($0, texture: texture, dark: dark) }))
            if let shown, ready == nil {
                let fades = artImage == nil
                artLoad = Task { [weak self, images] in
                    let image = await images.image(shown, texture: texture, dark: dark)
                    guard !Task.isCancelled, let self, let image else { return }
                    self.showArt(image)
                    if fades, let layer = self.artView.layer { Motion.panes.set(layer, "opacity", to: self.artOpacity, fade: .fadeIn, from: 0) }
                }
            }
        }
        artView.isHidden = hidesArt || artImage == nil
        showsVideo = !hidesArt && shown?.isVideo == true
        videoView.show(showsVideo ? shown?.resolvedImageURL(dark: dark) : nil)
        // Window Glass: the desktop shows through the art. The model value only, so a fade-in in
        // flight runs on to it.
        artOpacity = Float(backdrop.artOpacity)
        if artView.layer?.opacity != artOpacity { artView.layer?.opacity = artOpacity }
        if videoView.layer?.opacity != artOpacity { videoView.layer?.opacity = artOpacity }
        if backdrop.material != material {
            material = backdrop.material
            materialView?.removeFromSuperview()
            materialView = Self.makeMaterialView(material, activeLook: activeLook)
            if let materialView {
                materialView.frame = bounds
                materialView.autoresizingMask = [.width, .height]
                addSubview(materialView, positioned: .below, relativeTo: glassTint.overlay)
            }
        }
        // Frosted over art blurs the art itself (and a video over it), by the material's radius.
        applyArtBlur(backdrop.artBlurRadius)
        let alpha = backdrop.tintOpacity * (1 - backdrop.tuning.glassTransparency)
        // Where the desktop shows through, the tint takes its picture's hue (appearance.wallpaperTint).
        let leaned = WallpaperTint.tint(tint, wallpaper: wallpaper.tint, enabled: wallpaper.tintEnabled,
                                        material: backdrop.material, shown: shown)
        let color = tunedTint(leaned, tuning: backdrop.tuning).withAlphaComponent(alpha)
        washColor = material == .opaque ? nil : color.withAlphaComponent(1).cgColor
        let glass = materialView as? GlassPanelView
        // Liquid Glass takes the new tint once; an overlay blends from the old one on the render
        // server (appearance.colorTransition).
        if let glass { glassTint.set(glass, to: color, in: self) }
        // Glass tints itself; a tint view over it would dim the desktop twice.
        let shows = material != .opaque && glass == nil
        tintView.isHidden = !shows
        let tint = shows ? color.cgColor : nil
        if let layer = tintView.layer, layer.backgroundColor != tint {
            // The tint over the desktop blends like the opaque sheet (appearance.colorTransition).
            if tint != nil, layer.backgroundColor != nil, window?.isVisible == true {
                ColorTransition.current.animate(layer, to: tint)
            } else {
                layer.removeAnimation(forKey: ColorTransition.layerKey)
                layer.backgroundColor = tint
            }
        }
        updateInactiveTint()
        noteGlassSourceChange()
    }

    /// The desktop picture or its color changed (``DesktopWallpaperWatch``), or
    /// `appearance.wallpaperTint` did: a view that shows the desktop applies its backdrop again.
    func desktopWallpaperDidChange() {
        guard let applied else { return }
        let shown = applied.backdrop.selection ?? applied.backdrop.art.map(BackdropSelection.art)
        guard shown == nil || shown == .desktop else { return }
        apply(applied.backdrop, tint: applied.tint)
    }

    private func showArt(_ image: NSImage?) {
        artImage = image
        artView.layer?.contents = artImage
        artView.isHidden = hidesArt || artImage == nil
        noteGlassSourceChange()
    }

    /// Blurs the art and the video over it by `radius` points (``WindowBackdrop/artBlurRadius``);
    /// 0 clears the blur. Filters are made for each view: they are mutable objects.
    private func applyArtBlur(_ radius: Int) {
        guard radius != artBlurRadius else { return }
        artBlurRadius = radius
        for view in [artView, videoView as NSView] {
            if radius > 0 { view.layerUsesCoreImageFilters = true }
            // Clamped first: the blur then reads the edge pixels past the edge, not transparency,
            // so the picture keeps no translucent rim.
            view.layer?.filters = radius > 0
                ? [CIFilter(name: "CIAffineClamp"), CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])]
                    .compactMap { $0 } : nil
        }
    }

    /// The backdrop behind `window`'s content: its content view, or a direct subview of it.
    public static func backdrop(of window: NSWindow?) -> WindowMaterialView? {
        guard let content = window?.contentView else { return nil }
        return content as? WindowMaterialView ?? content.subviews.lazy.compactMap { $0 as? WindowMaterialView }.first
    }

    private func tunedTint(_ tint: NSColor, tuning: AppearanceTuning) -> NSColor {
        guard let rgb = tint.usingColorSpace(.deviceRGB) else { return tint }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let shifted = (hue + CGFloat(tuning.hue - 0.5)).truncatingRemainder(dividingBy: 1)
        return NSColor(deviceHue: shifted < 0 ? shifted + 1 : shifted,
                       saturation: min(max(saturation * CGFloat(tuning.saturation), 0), 1),
                       brightness: brightness,
                       alpha: alpha)
    }

    private static func makeMaterialView(_ material: WindowMaterial, activeLook: ActiveLookScope?) -> NSView? {
        switch material {
        case .opaque, .translucent, .frosted:
            return nil
        case .glass(let style):
            // WindowBackdrop frosts the window instead where Liquid Glass is missing.
            switch style {
            case .regular: return GlassPanelView(style: .regular, activeLook: activeLook)
            case .clear: return GlassPanelView(style: .clear, activeLook: activeLook)
            }
        }
    }
}
