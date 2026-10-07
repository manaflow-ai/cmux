public import AppKit

/// The one material behind a window's content (``WindowMaterial``) and the
/// one theme tint, as the window root's bottom subview.
///
/// It hosts at most one material view: an `NSGlassEffectView` for
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
    private let artView = NSView()
    private var loadedSelection: BackdropSelection?
    private var loadedArt: BackdropArt?
    private var loadedTexture: BackdropTexture?
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
    public init(frame frameRect: NSRect, images: BackdropImageStore) {
        self.images = images
        super.init(frame: frameRect)
        artView.wantsLayer = true
        artView.frame = bounds
        artView.autoresizingMask = [.width, .height]
        artView.layer?.contentsGravity = .resizeAspectFill
        artView.layer?.masksToBounds = true
        artView.isHidden = true
        addSubview(artView)
        tintView.wantsLayer = true
        tintView.frame = bounds
        tintView.autoresizingMask = [.width, .height]
        tintView.isHidden = true
        addSubview(tintView)
        setAccessibilityElement(false)
    }

    override public func layout() {
        super.layout()
        updateArtCrop()
    }

    /// Waits until the art the last `apply` asked for has loaded (tests).
    func artLoaded() async { await artLoad?.value }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The one theme tint at the backdrop's opacity: the glass view's own
    /// tint for glass, otherwise the color laid over the desktop; nil while
    /// opaque.
    public var tintColor: CGColor? {
        if let glass = materialView as? NSGlassEffectView { return glass.tintColor?.cgColor }
        return tintView.isHidden ? nil : tintView.layer?.backgroundColor
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
        if loadedSelection != backdrop.selection || loadedArt != backdrop.art || loadedTexture != backdrop.texture {
            loadedSelection = backdrop.selection
            loadedArt = backdrop.art
            loadedTexture = backdrop.texture
            artLoad?.cancel()
            artLoad = nil
            let shown = backdrop.selection ?? backdrop.art.map(BackdropSelection.art)
            let texture = backdrop.texture
            // Decoded art shows at once. Otherwise an earlier launch's snapshot shows in this
            // first frame, and the full image replaces it in place; without one the window shows
            // the theme's colors until the art, decoded off the main actor, fades in.
            let ready = shown.flatMap { images.cached($0, texture: texture) }
            showArt(ready ?? (hidesArt ? nil : shown.flatMap { images.preview($0, texture: texture) }))
            if let shown, ready == nil {
                let fades = artImage == nil
                artLoad = Task { [weak self, images] in
                    let image = await images.image(shown, texture: texture)
                    guard !Task.isCancelled, let self, let image else { return }
                    self.showArt(image)
                    if fades { self.artView.layer?.add(Self.fadeIn(), forKey: "fadeIn") }
                }
            }
        }
        artView.isHidden = hidesArt || artImage == nil
        if backdrop.material != material {
            material = backdrop.material
            materialView?.removeFromSuperview()
            materialView = Self.makeMaterialView(material)
            if let materialView {
                materialView.frame = bounds
                materialView.autoresizingMask = [.width, .height]
                addSubview(materialView, positioned: .below, relativeTo: tintView)
            }
        }
        let alpha = backdrop.tintOpacity * (1 - backdrop.tuning.glassTransparency)
        let color = tunedTint(tint, tuning: backdrop.tuning).withAlphaComponent(alpha)
        let glass = materialView as? NSGlassEffectView
        glass?.tintColor = color
        // Glass tints itself; a tint view over it would dim the desktop twice.
        let shows = material != .opaque && glass == nil
        tintView.isHidden = !shows
        tintView.layer?.backgroundColor = shows ? color.cgColor : nil
    }

    private func showArt(_ image: NSImage?) {
        artImage = image
        artView.layer?.contents = artImage
        artView.isHidden = hidesArt || artImage == nil
        updateArtCrop()
    }

    private static func fadeIn() -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        return fade
    }

    private func updateArtCrop() {
        guard let layer = artView.layer, let image = artImage else {
            artView.layer?.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
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
            metadata = BackdropArtMetadata(focalAnchor: .center, tone: .light,
                                           dominantPalette: [], quietZone: .init(x: 0, y: 0, width: 1, height: 1))
        }
        layer.contentsRect = metadata.cropRect(forViewSize: bounds.size, imageSize: image.size)
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
            let glass = NSGlassEffectView()
            glass.cornerRadius = 0
            switch style {
            case .regular: glass.style = .regular
            case .clear: glass.style = .clear
            }
            return glass
        }
    }
}
