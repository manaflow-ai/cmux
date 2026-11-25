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
/// background. Neither the material nor the tint draws a border: a backdrop that
/// ``fillsWindow`` runs its glass past the window's edges, so the window clips the
/// highlight Liquid Glass draws along its own edges.
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
    /// The agents' glow over the backdrop (`appearance.agentGlow`); it follows the agents only in a
    /// window's own backdrop (one made with an ``activeLook``), never a pane's.
    let agentGlowView = BackdropAgentGlowView()
    /// The keyboard left the window's family: another app, or a window that is not this one, its
    /// child (a Chromium page window, popup, palette) or its sheet. Only then does the window look
    /// inactive (Leo 2026-10-21: "on itself? that should never happen"); a window whose family
    /// never held the keyboard (opening, tests, snapshots) shows the glass alone.
    private var resignedKey: Bool { keyFamily?.isInactive ?? false }
    /// The art layer (tests read what it shows): the whole image aspect-filled over the whole
    /// view, centered, like a macOS wallpaper. Its frame autoresizes with the window, so nothing
    /// is computed per size and nothing jumps while resizing.
    let artView = NSView()
    /// Adjust Background…'s live placement while the person drags or zooms; nil shows the setting's
    /// (`WindowMaterialView+Placement.swift`).
    var previewPlacement: BackdropPlacement? {
        didSet { if previewPlacement != oldValue { applyPlacement() } }
    }
    /// The Adjust Background… overlay open over this backdrop; it is cancelled when the picture changes.
    weak var adjusting: BackdropAdjustOverlay?
    /// The art's own gravity and placement while a placement draws it (nil: none does), put back
    /// when it ends.
    var unplacedArtLook: (gravity: CALayerContentsGravity, placement: NSView.LayerContentsPlacement)?
    /// Follows `appearance.backgroundPlacement` (``DesignSettings/backgroundPlacements``).
    var placementWatch: Task<Void, Never>?
    /// Whether this backdrop fills its window, edge to edge (a window's backdrop, not a pane's own
    /// picture): its glass then runs ``glassOutset`` past every edge of the view.
    public let fillsWindow: Bool
    /// How far a window's glass runs past each edge of the window, in points. Liquid Glass draws a
    /// bright highlight and a lens band along its own edges, strongest at the top and bottom; on the
    /// window's edge they read as a white line over the window's own rim (the user, 2026-11-19, on
    /// macOS 27: "weird white border at top of window"). Past the edge the window clips them, and
    /// the window keeps one even rim on all four sides. 4 points clipped them in a real capture; 8
    /// leaves room for the lens band at 2x.
    static let glassOutset: CGFloat = 8
    /// The art layer's opacity (`WindowBackdrop.artOpacity`), the end of its fade-in.
    private(set) var artOpacity: Float = 1
    /// Tests crossfade a view that is in no visible window (a test host may have no screen).
    var crossfadesOffScreen = false
    private(set) var loadedSelection: BackdropSelection?
    private var loadedArt: BackdropArt?
    private var loadedTexture: BackdropTexture?
    /// The appearance the art loaded for: a dynamic Apple picture or shipped video has one of each.
    private(set) var loadedDark = false
    /// The desktop's ``DesktopWallpaperWatch/generation`` the Desktop Wallpaper art loaded for.
    private var loadedDesktopGeneration = 0
    /// What the Desktop Wallpaper drew last (its screen's picture, movie or frame), and the
    /// display it was read for: a window moved to another display reloads.
    private var loadedDesktop: BackdropSelection?
    var loadedDesktopScreen: UInt32?
    /// The backdrop shows the Desktop Wallpaper (``BackdropSelection/desktop``).
    private(set) var followsDesktop = false
    /// How the art is placed: the Desktop Wallpaper's screen's Fill, Fit, Stretch or Center;
    /// every other background fills (``applyArtFit(_:)``).
    var artFit: BackdropArtFit = .fill
    /// The last `apply`, run again when the appearance flips under art that follows it.
    private var applied: (backdrop: WindowBackdrop, tint: NSColor)?
    /// A video wallpaper over the art (its poster), playing while seen (``BackdropVideoView``).
    public let videoView: BackdropVideoView
    /// A living wallpaper over the art (its still), drawn every frame while seen (``BackdropShaderView``).
    public let shaderView: BackdropShaderView
    private(set) var artImage: NSImage? {
        didSet {
            guard artImage !== oldValue else { return }
            artLight = artImage.flatMap(images.lightField(of:))
            images.light.artDidChange()
        }
    }
    /// The shown art's light field, read in its decode (nil for a preview or a video's poster).
    private(set) var artLight: WallpaperLightField?
    /// A video wallpaper plays over the art (pages get no still of it, `glassSource`).
    private(set) var showsVideo = false
    /// A live wallpaper (`live:<id>`) runs in place of the art (``BackdropLiveView``).
    public let liveView: BackdropLiveView
    /// A live wallpaper shows (pages get no still of it, `glassSource`).
    private(set) var showsLive = false
    /// A living wallpaper draws over the art (pages get no still of it, `glassSource`).
    private(set) var showsShader = false
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
    /// The art's blurred copy under Frosted (``artContents(for:)``), and the job making the next one.
    var blurredArt: ArtBlur.Copy?
    var artBlurJob: Task<Void, Never>?
    /// Holds the video and the living wallpaper, clipped to this view: under Frosted they run
    /// ``liveBlurReach(_:)`` past every edge, so their blur's fading rim falls outside it.
    let liveArtClip = NSView()

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
    /// - Parameter fillsWindow: True for a window's backdrop, edge to edge: its glass runs past the
    ///   window's edges (``fillsWindow``). False, the default, keeps the glass inside the view (a
    ///   pane's own picture, beside other panes).
    public init(frame frameRect: NSRect, images: BackdropImageStore, videos: BackdropVideoPlayers = .shared,
                activeLook: ActiveLookScope? = nil, fillsWindow: Bool = false) {
        self.images = images
        self.activeLook = activeLook
        self.fillsWindow = fillsWindow
        videoView = BackdropVideoView(frame: frameRect, players: videos)
        liveView = BackdropLiveView(frame: frameRect, programs: images.livePrograms)
        shaderView = BackdropShaderView(frame: frameRect, renderer: images.shaders)
        super.init(frame: frameRect)
        artView.wantsLayer = true
        artView.frame = bounds
        artView.autoresizingMask = [.width, .height]
        // AppKit sets a backing layer's gravity from its placement: both say fill (a custom picture showed bottom-left).
        artView.layerContentsRedrawPolicy = .never
        artView.layerContentsPlacement = .scaleProportionallyToFill
        artView.layer?.contentsGravity = .resizeAspectFill
        artView.layer?.masksToBounds = true
        artView.isHidden = true
        addSubview(artView)
        liveArtClip.wantsLayer = true
        liveArtClip.frame = bounds
        liveArtClip.autoresizingMask = [.width, .height]
        liveArtClip.layer?.masksToBounds = true
        addSubview(liveArtClip)
        videoView.frame = liveArtClip.bounds
        videoView.autoresizingMask = [.width, .height]
        liveArtClip.addSubview(videoView)
        liveView.frame = liveArtClip.bounds
        liveView.autoresizingMask = [.width, .height]
        liveArtClip.addSubview(liveView)
        shaderView.frame = liveArtClip.bounds
        shaderView.autoresizingMask = [.width, .height]
        liveArtClip.addSubview(shaderView)
        // The living wallpaper moves on the video wallpaper's terms, through its observers.
        shaderView.sight = { [weak videoView] in (videoView?.screensAsleep ?? false, videoView?.sessionInactive ?? false) }
        videoView.onSightChange = { [weak shaderView] closing in shaderView?.sightChanged(closing: closing) }
        glassTint.overlay.frame = bounds
        glassTint.overlay.autoresizingMask = [.width, .height]
        addSubview(glassTint.overlay)
        tintView.wantsLayer = true
        tintView.frame = bounds
        tintView.autoresizingMask = [.width, .height]
        tintView.isHidden = true
        addSubview(tintView)
        agentGlowView.frame = bounds
        addSubview(agentGlowView)
        if activeLook != nil { agentGlowView.follow() }
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
        observePlacement()
    }

    override public func layout() {
        super.layout()
        applyPlacement()
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
        let chosen = backdrop.selection ?? backdrop.art.map(BackdropSelection.art)
        let flipped = chosen?.followsAppearance == true && loadedDark != dark
        // Light and Dark draws its side for this view's appearance.
        let picked = chosen?.resolved(dark: dark)
        followsDesktop = picked == .desktop
        // The Desktop Wallpaper draws what this window's own screen shows (until the first reading,
        // the desktop as read now): its picture, aerial or frame of the time, placed as macOS does.
        let desktop = followsDesktop ? wallpaper.shown(on: window?.screen) : nil
        let shown = desktop?.selection(dark: dark) ?? picked
        // A live wallpaper draws itself: no picture loads under it.
        let live = shown?.liveID
        let pictured = live == nil ? shown : nil
        applyArtFit(desktop)
        loadedDesktopScreen = followsDesktop ? window?.screen.flatMap(DesktopWallpaperWatch.displayID) : nil
        if followsDesktop { wallpaper.desktopIsShown() }
        // The desktop moved on (a new picture, a Space with its own, another display): it reloads.
        let desktopMoved = followsDesktop && (loadedDesktopGeneration != wallpaper.generation || loadedDesktop != shown)
        if loadedSelection != backdrop.selection || loadedArt != backdrop.art || loadedTexture != backdrop.texture || flipped || desktopMoved {
            loadedSelection = backdrop.selection
            loadedArt = backdrop.art
            loadedTexture = backdrop.texture
            loadedDark = dark
            loadedDesktopGeneration = wallpaper.generation
            cancelAdjustingAnotherPicture()
            loadedDesktop = followsDesktop ? shown : nil
            if followsDesktop { images.forgetDesktopPicture(olderThan: wallpaper.generation) }
            artLoad?.cancel()
            artLoad = nil
            let texture = backdrop.texture, desktopEntry = followsDesktop
            // A picture already shown stays until the new one decodes, then crossfades into it. With
            // none shown, decoded art shows at once, else an earlier launch's snapshot shows in this
            // first frame and the full image replaces it; without one the theme's colors until the
            // art, decoded off the main actor, fades in.
            let ready = pictured.flatMap { images.cached($0, texture: texture, dark: dark, desktop: desktopEntry) }
            let keeps = pictured != nil && artImage != nil && !hidesArt
            if keeps { if let ready { crossfadeArt(to: ready) } } else {
                showArt(ready ?? (hidesArt ? nil : pictured.flatMap { images.preview($0, texture: texture, dark: dark) }))
            }
            if let pictured, ready == nil {
                let fades = artImage == nil
                artLoad = Task { [weak self, images] in
                    let image = await images.image(pictured, texture: texture, dark: dark, desktop: desktopEntry)
                    guard !Task.isCancelled, let self else { return }
                    guard let image else { if keeps { self.showArt(nil) }; return }
                    self.crossfadeArt(to: image)
                    if fades, let layer = self.artView.layer { Motion.panes.set(layer, "opacity", to: self.artOpacity, fade: .fadeIn, from: 0) }
                }
            }
        }
        artView.isHidden = hidesArt || artImage == nil
        showsVideo = !hidesArt && shown?.isVideo == true
        videoView.show(showsVideo ? shown?.resolvedImageURL(dark: dark) : nil)
        showsLive = !hidesArt && live != nil
        liveView.show(showsLive ? live.flatMap(LiveWallpaper.named) : nil)
        // Every theme apply: new colors are activity, and a held wallpaper redraws once in them.
        if showsLive { liveView.themeDidChange() }
        // TODO(gcp-codex-lane-11/wallpaper-lighting): hand Wallpaper Lighting one 256-px-wide still per
        // wallpaper or theme change (LiveWallpaperRenderer.still, read with WallpaperLightField.read),
        // then artDidChange(), once WindowMaterialView.setArtLight lands from that lane.
        let shader = hidesArt ? nil : shown?.shader
        showsShader = shader != nil
        shaderView.show(shader, dark: dark)
        // Window Glass: the desktop shows through the art. The model value only, so a fade-in in
        // flight runs on to it.
        artOpacity = Float(backdrop.artOpacity)
        if artView.layer?.opacity != artOpacity { artView.layer?.opacity = artOpacity }
        if videoView.layer?.opacity != artOpacity { videoView.layer?.opacity = artOpacity }
        if liveView.layer?.opacity != artOpacity { liveView.layer?.opacity = artOpacity }
        if shaderView.layer?.opacity != artOpacity { shaderView.layer?.opacity = artOpacity }
        if backdrop.material != material {
            material = backdrop.material
            materialView?.removeFromSuperview()
            materialView = Self.makeMaterialView(material, activeLook: activeLook)
            if let materialView {
                // Flexible width and height keep the outset through every resize.
                let outset = fillsWindow ? Self.glassOutset : 0
                materialView.frame = bounds.insetBy(dx: -outset, dy: -outset)
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
        let shown = (applied.backdrop.selection ?? applied.backdrop.art.map(BackdropSelection.art))?.resolved(dark: loadedDark)
        guard shown == nil || shown == .desktop else { return }
        apply(applied.backdrop, tint: applied.tint)
    }

    func showArt(_ image: NSImage?) {
        artImage = image
        artView.layer?.contents = artContents(for: image)
        artView.isHidden = hidesArt || artImage == nil
        applyPlacement()
        noteGlassSourceChange()
    }

    /// Blurs the art and the video or live wallpaper over it by `radius` points (``WindowBackdrop/artBlurRadius``);
    /// 0 clears the blur. The picture takes a blurred copy (``ArtBlur``): a filter on its
    /// aspect-filled layer drew it in the bottom-left. Filters are made for each view: they are
    /// mutable objects.
    private func applyArtBlur(_ radius: Int) {
        guard radius != artBlurRadius else { return }
        artBlurRadius = radius
        if artImage != nil { artView.layer?.contents = artContents(for: artImage) }
        // The video and living wallpaper change every frame, so they keep a live filter: the blur
        // alone. A CIAffineClamp before it (an infinite extent) filled only the bottom left at 2x,
        // as it did on the still (scripts/measure/frosted-art-2x.sh, cmux#51381). The views run past
        // the clip instead, so the blur's edges read the picture and its fading rim is cut off.
        let reach = Self.liveBlurReach(radius)
        for view in [videoView as NSView, liveView as NSView, shaderView as NSView] {
            if radius > 0 { view.layerUsesCoreImageFilters = true }
            view.frame = liveArtClip.bounds.insetBy(dx: -reach, dy: -reach)
            view.layer?.filters = radius > 0
                ? [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])].compactMap { $0 } : nil
        }
    }

    /// How far a blurred video or living wallpaper runs past each edge, in points: three times the
    /// blur's radius, where a Gaussian's weight is spent.
    static func liveBlurReach(_ radius: Int) -> CGFloat { CGFloat(max(radius, 0) * 3) }

    /// The backdrop behind `window`'s content: its content view, or a direct subview of it.
    public static func backdrop(of window: NSWindow?) -> WindowMaterialView? {
        guard let content = window?.contentView else { return nil }
        return content as? WindowMaterialView ?? content.subviews.lazy.compactMap { $0 as? WindowMaterialView }.first
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
