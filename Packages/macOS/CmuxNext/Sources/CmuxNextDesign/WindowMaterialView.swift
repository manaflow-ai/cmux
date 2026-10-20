public import AppKit
import CoreImage

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
    private let inactiveTintView = NSView()
    private var keyObservers: [NSObjectProtocol] = []
    /// The window gave up the keyboard. Only then does glass go grey; a window
    /// that was never key (opening, tests, snapshots) shows the glass alone.
    private var resignedKey = false
    /// The art layer (tests read what it shows).
    let artView = NSView()
    /// A blurred copy of the art behind it, shown while the art shrinks to keep its subject whole
    /// (``BackdropArtPlacement/fills``).
    let artFillView = NSView()
    /// Where the art lies now (tests).
    private(set) var artPlacement: BackdropArtPlacement?
    /// The x ranges, in this view's points, that the sidebar and a docked agent chat cover: the
    /// art keeps its subject in the widest stretch between them (``BackdropVisibleSpan``).
    public var coveredColumns: [ClosedRange<CGFloat>] = [] {
        // A column that comes or goes moves the art on a spring; one resized (a divider drag, a
        // window resize, the sidebar's slide) moves it at once, frame by frame with the column.
        didSet {
            if coveredColumns != oldValue {
                updateArtCrop(animated: coveredColumns.count != oldValue.count && window?.inLiveResize != true)
            }
        }
    }
    /// The columns over the art by who reported them, in window coordinates (``setCover(_:for:)``).
    private var covers: [String: CGRect] = [:]
    /// The art layer's opacity (`WindowBackdrop.artOpacity`), the end of its fade-in.
    private var artOpacity: Float = 1
    private var loadedSelection: BackdropSelection?
    private var loadedArt: BackdropArt?
    private var loadedTexture: BackdropTexture?
    /// The appearance the art loaded for: a dynamic Apple picture or shipped video has one of each.
    private var loadedDark = false
    /// The last `apply`, run again when the appearance flips under art that follows it.
    private var applied: (backdrop: WindowBackdrop, tint: NSColor)?
    /// A video wallpaper over the art (its poster), playing while seen (``BackdropVideoView``).
    public let videoView: BackdropVideoView
    private var artImage: NSImage?
    private let images: BackdropImageStore
    /// Loads the art the last `apply` asked for when it was not decoded yet.
    private var artLoad: Task<Void, Never>?
    /// The solid sheet and Reduce Transparency must never expose art.
    private var hidesArt = false

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
    public init(frame frameRect: NSRect, images: BackdropImageStore, videos: BackdropVideoPlayers = .shared) {
        self.images = images
        videoView = BackdropVideoView(frame: frameRect, players: videos)
        super.init(frame: frameRect)
        artFillView.wantsLayer = true
        artFillView.layerUsesCoreImageFilters = true
        artFillView.frame = bounds
        artFillView.autoresizingMask = [.width, .height]
        artFillView.layer?.contentsGravity = .resizeAspectFill
        artFillView.layer?.masksToBounds = true
        artFillView.isHidden = true
        addSubview(artFillView)
        artView.wantsLayer = true
        artView.frame = bounds
        // The placement sets the frame and the part of the image shown, at the image's own aspect.
        artView.layer?.contentsGravity = .resize
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
        addSubview(inactiveTintView)
        setAccessibilityElement(false)
    }

    override public func layout() {
        super.layout()
        updateArtCrop()
    }

    /// The art is the only layer whose frame is computed, not autoresized: every size change
    /// places it again at once. `layout()` alone is not enough, since a superview's autoresize
    /// can change this frame without asking for layout, which left the art at the old window's
    /// frame over a stretched blurred fill after a resize.
    override public func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { updateArtCrop() }
    }

    override public func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateArtCrop()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // A display or scale change: the placement is pixel-sensitive.
        artPlacement = nil
        updateArtCrop()
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

    /// The theme tint laid over glass while the window is not key: Liquid
    /// Glass drops its `tintColor` then and draws the system's grey, so the
    /// tint comes back over it, as cmux classic does (dogfood 2026-10-08, C3).
    var inactiveTintAlpha: CGFloat { inactiveTintView.isHidden ? 0 : inactiveTintView.alphaValue }

    /// Classic's wash over inactive glass: strong over a dark theme, light
    /// over a light one, none while the window is key or for other materials.
    static func inactiveTintAlpha(isGlass: Bool, isKeyWindow: Bool, tint: NSColor) -> CGFloat {
        guard isGlass, !isKeyWindow else { return 0 }
        guard let rgb = tint.usingColorSpace(.sRGB) else { return 0.85 }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.5 ? 0.35 : 0.85
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // A dynamic Apple picture or a shipped video has a light and a dark file.
        if let applied, applied.backdrop.selection?.followsAppearance == true { apply(applied.backdrop, tint: applied.tint) }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
        keyObservers = []
        resignedKey = false
        guard let window else { return updateInactiveTint() }
        keyObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                let resigned = note.name == NSWindow.didResignKeyNotification
                // main-proof: the observer runs on the main queue (queue: .main)
                MainActor.assumeIsolated {
                    self?.resignedKey = resigned
                    self?.updateInactiveTint()
                }
            }
        }
        updateInactiveTint()
    }

    private func updateInactiveTint() {
        let glass = materialView as? GlassPanelView
        let alpha = glass?.tintColor.map { Self.inactiveTintAlpha(isGlass: true, isKeyWindow: !resignedKey, tint: $0) } ?? 0
        let wash = alpha > 0 ? glass?.tintColor?.cgColor : nil
        // A tint change blends the wash like the glass under it; showing or hiding it applies at once.
        if let layer = inactiveTintView.layer, layer.backgroundColor != wash {
            if wash != nil, layer.backgroundColor != nil, !inactiveTintView.isHidden, window?.isVisible == true {
                ColorTransition.current.animate(layer, to: wash)
            } else {
                layer.removeAnimation(forKey: ColorTransition.layerKey)
                layer.backgroundColor = wash
            }
        }
        inactiveTintView.alphaValue = alpha
        inactiveTintView.isHidden = alpha == 0
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
                artLoad = Task { [weak self, images] in
                    let image = await images.image(shown, texture: texture, dark: dark)
                    guard !Task.isCancelled, let self, let image else { return }
                    self.showArt(image)
                    if fades, let layer = self.artView.layer { Motion.set(layer, "opacity", to: self.artOpacity, fade: .fadeIn, from: 0) }
                }
            }
        }
        artView.isHidden = hidesArt || artImage == nil
        artFillView.isHidden = artView.isHidden || artPlacement?.fills != true
        videoView.show(hidesArt || shown?.isVideo != true ? nil : shown?.resolvedImageURL(dark: dark))
        // Window Glass: the desktop shows through the art. The model value only, so a fade-in in
        // flight runs on to it.
        artOpacity = Float(backdrop.artOpacity)
        if artView.layer?.opacity != artOpacity { artView.layer?.opacity = artOpacity }
        if artFillView.layer?.opacity != artOpacity { artFillView.layer?.opacity = artOpacity }
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
        // Over art the tuner thins the glass only down to the legible tint.
        let alpha = max(backdrop.tintOpacity * (1 - backdrop.tuning.glassTransparency), backdrop.legibleTintOpacity)
        let color = tunedTint(tint, tuning: backdrop.tuning).withAlphaComponent(alpha)
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
    }

    private func showArt(_ image: NSImage?) {
        artImage = image
        artView.layer?.contents = artImage
        artFillView.layer?.contents = artImage
        artView.isHidden = hidesArt || artImage == nil
        updateArtCrop()
    }

    /// The blur of the fill behind shrunk art: enough that it reads as the art's own light, never
    /// as a second picture, in the art's own tone. Made for each view: filters are mutable objects.
    static func fillFilters() -> [CIFilter] {
        // Blur only: a dimmed fill read as a darker sidebar beside the art (Lawrence 2026-10-19,
        // "not a different color"), so the fill keeps the art's own tone.
        let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 48])
        return [blur].compactMap { $0 }
    }

    /// Places the art (``BackdropArtMetadata/placement(forViewSize:imageSize:visible:)``): on a
    /// resize at once, and with the move spring when the columns over it change.
    private func updateArtCrop(animated: Bool = false) {
        guard let layer = artView.layer, let image = artImage else {
            artPlacement = nil
            artView.layer?.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            artView.frame = bounds
            artFillView.isHidden = true
            return
        }
        let metadata: BackdropArtMetadata
        if let art = loadedSelection.flatMap({ selection in
            if case .art(let art) = selection { return art }
            return nil
        }) {
            metadata = art.metadata
        } else if let art = loadedArt {
            metadata = art.metadata
        } else {
            // Your own image: its whole self is the subject, so it centers as before and only
            // shifts as far as covering the window allows.
            metadata = BackdropArtMetadata(focalAnchor: .center, tone: .light,
                                           dominantPalette: [], quietZone: .init(x: 0, y: 0, width: 1, height: 1),
                                           subjectBox: .init(minX: 0, minY: 0, maxX: 1, maxY: 1))
        }
        let visible = BackdropVisibleSpan.uncovered(width: bounds.width, by: coveredColumns)
        let placement = metadata.placement(forViewSize: bounds.size, imageSize: image.size, visible: visible)
        let fills = placement.fills && !artView.isHidden
        if fills, artFillView.layer?.filters == nil { artFillView.layer?.filters = Self.fillFilters() }
        artFillView.isHidden = !fills
        guard placement != artPlacement else { return }
        artPlacement = placement
        if animated, window != nil {
            Motion.set(layer, "contentsRect", to: NSValue(rect: placement.contentsRect), spring: .move)
            Motion.animate(.move, in: self) { artView.animator().frame = placement.frame }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "contentsRect")
            layer.contentsRect = placement.contentsRect
            artView.frame = placement.frame
            CATransaction.commit()
        }
    }

    /// The backdrop behind `window`'s content: its content view, or a direct subview of it.
    public static func backdrop(of window: NSWindow?) -> WindowMaterialView? {
        guard let content = window?.contentView else { return nil }
        return content as? WindowMaterialView ?? content.subviews.lazy.compactMap { $0 as? WindowMaterialView }.first
    }

    /// Records the column `source` lays over the art (`frameInWindow` in window coordinates; nil
    /// when it is gone): the sidebar and each workspace's docked agent chat report themselves.
    public func setCover(_ frameInWindow: CGRect?, for source: String) {
        guard covers[source] != frameInWindow else { return }
        covers[source] = frameInWindow
        coveredColumns = covers.keys.sorted().compactMap { key in
            guard let frame = covers[key].map({ convert($0, from: nil) }), frame.width > 0.5 else { return nil }
            return frame.minX...frame.maxX
        }
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
