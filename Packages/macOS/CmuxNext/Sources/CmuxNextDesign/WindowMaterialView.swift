public import AppKit
import CoreImage
import CmuxNextCompat
public import CmuxNextWakeups
public import CmuxNextDesignTokens
public import CmuxNextAppearance

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
/// a second tint over it dimmed the desktop twice. Neither the material nor the tint draws a border.
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
    /// The inactive wash sits under the in-app art. Native glass can still use it to cover the
    /// desktop when it drops its active tint, while the person's own background remains visible.
    let inactiveTintView = NSView()
    /// The inactive wash's alpha once its fade ends (`updateInactiveTint`).
    private var inactiveTintTarget: CGFloat = 0
    /// The theme tint at full alpha, the inactive wash's color; nil while opaque.
    private var washColor: CGColor?
    /// The tint's alpha (the backdrop's opacity), from which the wash over inactive glass is derived.
    private var tintAlpha: CGFloat = 1
    /// Bumped by each wash fade: only the latest fade-out's completion hides the view (a
    /// replaced animation completes too).
    private var inactiveTintFade = 0
    /// The window's key tracker; it says whether the window looks inactive and calls
    /// ``updateInactiveTint()`` when that flips.
    private var keyFamily: WindowKeyFamily?
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
    /// Whether a view is in a live window resize (`NSView.inLiveResize`; tests pass their own).
    private let liveResize: @MainActor (NSView) -> Bool
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
    /// - Parameter liveResize: Whether a view is in a live window resize (`NSView.inLiveResize`).
    public init(frame frameRect: NSRect, images: BackdropImageStore, videos: BackdropVideoPlayers = .shared,
                liveResize: @escaping @MainActor (NSView) -> Bool = { $0.inLiveResize }) {
        self.images = images
        self.liveResize = liveResize
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

    /// The theme tint laid over the window while it is not key, at full alpha. Liquid Glass drops
    /// its `tintColor` then and draws the system's grey, so the tint comes back over it at the
    /// strength that makes the inactive window look like the key one (dogfood 2026-10-08, C3), plus
    /// `appearance.inactiveWindowDim`. Its resting alpha: where its fade ends.
    var inactiveTintAlpha: CGFloat { inactiveTintTarget }

    /// How strongly the theme tint at full alpha covers glass that is not key so the window
    /// composites as it did while key: the tint Liquid Glass dropped, at its own alpha (the
    /// Opacity), over the material it covered. Not measured against the render server yet: CI and
    /// fleet test hosts have no window server to capture glass with.
    static func matchedGlassWash(tintAlpha: CGFloat) -> CGFloat {
        min(max(tintAlpha, 0), 1)
    }

    /// The wash over a window that is not key: none while it is key or opaque; over glass the
    /// match for the key look (``matchedGlassWash(tintAlpha:)``); then `dim` of what still shows
    /// through (`appearance.inactiveWindowDim`, 0 by default: the same look in front and behind).
    static func inactiveTintAlpha(material: WindowMaterial, isKeyWindow: Bool, tintAlpha: CGFloat, dim: CGFloat) -> CGFloat {
        guard material != .opaque, !isKeyWindow else { return 0 }
        let matched: CGFloat = if case .glass = material { matchedGlassWash(tintAlpha: tintAlpha) } else { 0 }
        let dim = min(max(dim, 0), 1)
        return matched + dim * (1 - matched)
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
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

    /// The art's place moves the pages lensing it (``noteGlassSourceChange()``) when its size is final: not per
    /// frame of a live window resize or of a pane spring, whose ends tell them (``viewDidEndLiveResize()``,
    /// `GlassBackdropFeed.landed()`).
    override public func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized, !liveResize(self), !isInPaneMotion { noteGlassSourceChange() }
    }

    override public func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        noteGlassSourceChange()
    }

    /// Makes `window`'s key tracker (the inactive wash of its material views) observe through the
    /// app's `events`: the composition root calls it before the window gets content. A later call
    /// for the same window changes nothing.
    public static func observeKeyFamily(of window: NSWindow, through events: AppEvents) {
        _ = WindowKeyFamily.of(window, environment: WindowKeyEnvironment(events: events))
    }

    /// Whether `key` (the key window, nil when none) is `window` or a window it owns, through
    /// `owner` (a window's parent or sheet parent).
    static func family<W: AnyObject>(of window: W, holds key: W?, owner: (W) -> W?) -> Bool {
        WindowEvents.family(of: window, holds: key, owner: owner)
    }

    /// A window looks inactive only once its family held the keyboard and then lost it to another
    /// app or another window; its own page windows, popups and sheets never make it look inactive.
    static func looksInactive(appActive: Bool, familyHoldsKey: Bool, familyHeldKey: Bool) -> Bool {
        guard familyHeldKey || (appActive && familyHoldsKey) else { return false }
        return !(appActive && familyHoldsKey)
    }

    func updateInactiveTint() {
        let alpha = washColor == nil ? 0 : Self.inactiveTintAlpha(material: material, isKeyWindow: !resignedKey, tintAlpha: tintAlpha,
                                                                   dim: CGFloat(DesignSettings.shared.inactiveWindowDim))
        let wash = alpha > 0 ? washColor : nil
        guard let layer = inactiveTintView.layer else { return }
        let previous = inactiveTintTarget
        inactiveTintTarget = alpha
        // Visible now, mid-fade included (the model opacity of a fading-out wash is already 0).
        let showing = !inactiveTintView.isHidden
        // The wash's color: a tint change while it shows blends like the glass under it. A wash
        // fading out keeps its color until it is gone.
        if let wash, layer.backgroundColor != wash {
            if layer.backgroundColor != nil, showing, window?.isVisible == true {
                ColorTransition.current.animate(layer, to: wash)
            } else {
                layer.removeAnimation(forKey: ColorTransition.layerKey)
                layer.backgroundColor = wash
            }
        }
        // Showing or hiding the wash eases (`scrim`): the palette taking the keys darkened the
        // whole window in one frame (Leo 2026-10-20). A window not on screen applies at once.
        guard window?.isVisible == true else {
            inactiveTintFade += 1
            layer.removeAnimation(forKey: "opacity")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = Float(alpha)
            CATransaction.commit()
            inactiveTintView.isHidden = alpha == 0
            return
        }
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
        if loadedSelection != backdrop.selection || loadedArt != backdrop.art || loadedTexture != backdrop.texture || flipped {
            loadedSelection = backdrop.selection
            loadedArt = backdrop.art
            loadedTexture = backdrop.texture
            loadedDark = dark
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
                // main-hop-allow: the store's main-actor cache decodes off main (a detached task); this task only awaits it,
                // and its one resume shows the art in this view, which the owner cancels on the next apply
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
            materialView = Self.makeMaterialView(material)
            if let materialView {
                materialView.frame = bounds
                materialView.autoresizingMask = [.width, .height]
                addSubview(materialView, positioned: .below, relativeTo: glassTint.overlay)
            }
        }
        // Frosted over art blurs the art itself (and a video over it), by the material's radius.
        applyArtBlur(backdrop.artBlurRadius)
        let alpha = backdrop.tintOpacity * (1 - backdrop.tuning.glassTransparency)
        let color = tunedTint(tint, tuning: backdrop.tuning).withAlphaComponent(alpha)
        tintAlpha = alpha
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
        // SAFETY: getHue writes one CGFloat into each of the four locals, live for the call.
        unsafe rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let shifted = (hue + CGFloat(tuning.hue - 0.5)).truncatingRemainder(dividingBy: 1)
        return NSColor(deviceHue: shifted < 0 ? shifted + 1 : shifted,
                       saturation: min(max(saturation * CGFloat(tuning.saturation), 0), 1),
                       brightness: brightness,
                       alpha: alpha)
    }

    private static func makeMaterialView(_ material: WindowMaterial) -> NSView? {
        switch material {
        case .opaque, .translucent, .frosted:
            return nil
        case .glass(let style):
            // WindowBackdrop frosts the window instead where Liquid Glass is missing.
            switch style {
            case .regular: return GlassPanelView(style: .regular)
            case .clear: return GlassPanelView(style: .clear)
            }
        }
    }
}
