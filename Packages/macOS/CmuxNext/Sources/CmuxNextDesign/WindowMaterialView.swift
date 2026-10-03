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
    private var loadedArt: BackdropArt?
    private var artImage: NSImage?

    /// Creates an opaque backdrop (no material view, no tint).
    ///
    /// - Parameter frameRect: The initial frame.
    override public init(frame frameRect: NSRect) {
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
        if loadedArt != backdrop.art {
            loadedArt = backdrop.art
            artImage = backdrop.art?.image()
            artView.layer?.contents = artImage
        }
        // The solid sheet and Reduce Transparency must never expose art.
        artView.isHidden = backdrop.isOpaque || artImage == nil
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
        let color = tint.withAlphaComponent(backdrop.tintOpacity)
        let glass = materialView as? NSGlassEffectView
        glass?.tintColor = color
        // Glass tints itself; a tint view over it would dim the desktop twice.
        let shows = material != .opaque && glass == nil
        tintView.isHidden = !shows
        tintView.layer?.backgroundColor = shows ? color.cgColor : nil
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
