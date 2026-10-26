public import AppKit
public import Foundation

/// The front window's saved picture (``WindowPictureStore``) as one layer: the launch's first frame is the window
/// at its saved frame, its live `WindowMaterialView`, and this view over it (p08-startup-059). The picture has no
/// backdrop in it (the quit draws the root without the material), so the live material shows through where only
/// the backdrop showed, blur and art included.
///
/// Chrome shows a saved capture of the first restored tab the same way and removes it once the live page paints
/// (chrome/android/java/src/org/chromium/chrome/browser/paint_preview/StartupPaintPreviewHelper.java).
///
/// The view draws nothing: its layer's contents are the decoded image at the window's backing scale, pinned to
/// the top-left corner (a window whose height changes keeps its titlebar and sidebar where the picture has them).
/// It takes no click and no key: hit tests pass through it to whatever is under it.
///
/// ```swift
/// let picture = LaunchPictureView(image: front.image, scale: 2)
/// picture.frame = window.contentView!.bounds
/// ```
public final class LaunchPictureView: NSView {
    /// The picture, `scale` pixels per point.
    public let image: CGImage
    public let scale: CGFloat

    public init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale > 0 ? scale : 1
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(image.width) / self.scale, height: CGFloat(image.height) / self.scale))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        needsDisplay = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var wantsUpdateLayer: Bool { true }
    override public var isOpaque: Bool { false }

    /// The picture's pixels as the layer's contents, 1:1 at `scale` and never stretched. On macOS a layer's
    /// "top" is its maximum y, the window's top in an unflipped view.
    override public func updateLayer() {
        guard let layer else { return }
        layer.contents = image
        layer.contentsScale = scale
        layer.contentsGravity = .topLeft
        layer.masksToBounds = true
    }

    /// Clicks reach the live views under the picture.
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension WindowPictureMeta {
    /// The fields where the saved meta `data` (``WindowPictureStore/FrontPicture/meta``, as the quit wrote it)
    /// differs from `opening`, the window the launch opens: empty, the picture shows that window and the launch
    /// shows it; anything else takes today's path. A meta that does not decode differs in every field.
    public static func mismatches(saved data: Data, opening: WindowPictureMeta) -> Set<Field> {
        guard let saved = try? JSONDecoder().decode(WindowPictureMeta.self, from: data) else { return Set(Field.allCases) }
        return saved.mismatches(opening)
    }
}
