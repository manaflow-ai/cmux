public import AppKit

/// The one material behind a window's content (``WindowMaterial``) and the
/// one theme tint over it, as the window root's bottom subview.
///
/// It hosts at most one material view: an `NSGlassEffectView` for
/// ``WindowMaterial/glass(_:)``, an `NSVisualEffectView` (`.behindWindow`,
/// `.active`, `.underWindowBackground`) for ``WindowMaterial/frosted``, and
/// none for ``WindowMaterial/translucent`` (only the tint) or
/// ``WindowMaterial/opaque``, where the root paints the solid background
/// itself. Neither the material nor the tint draws a border.
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

    /// Creates an opaque backdrop (no material view, no tint).
    ///
    /// - Parameter frameRect: The initial frame.
    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tintView.wantsLayer = true
        tintView.frame = bounds
        tintView.autoresizingMask = [.width, .height]
        tintView.isHidden = true
        addSubview(tintView)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The color laid over the material (or, see-through, over the desktop);
    /// nil while opaque.
    public var tintColor: CGColor? { tintView.isHidden ? nil : tintView.layer?.backgroundColor }

    /// Decoration only: clicks reach the views above or the window.
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `backdrop`'s material with `tint` over it at
    /// ``WindowBackdrop/tintOpacity``. The material view is replaced only
    /// when the material changes.
    ///
    /// - Parameter backdrop: The window's backdrop.
    /// - Parameter tint: The theme background; its alpha is replaced by
    ///   the backdrop's tint opacity.
    public func apply(_ backdrop: WindowBackdrop, tint: NSColor) {
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
        let shows = material != .opaque
        tintView.isHidden = !shows
        tintView.layer?.backgroundColor = shows ? tint.withAlphaComponent(backdrop.tintOpacity).cgColor : nil
    }

    private static func makeMaterialView(_ material: WindowMaterial) -> NSView? {
        switch material {
        case .opaque, .translucent:
            return nil
        case .frosted:
            let effect = NSVisualEffectView()
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .active
            return effect
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
