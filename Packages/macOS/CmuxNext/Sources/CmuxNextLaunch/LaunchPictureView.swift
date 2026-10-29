public import AppKit
public import Foundation

/// The front window's saved picture (``WindowPictureStore``) as one layer: the launch's first frame is the window
/// at its saved frame, its live `WindowMaterialView`, and this view over it. The picture has no
/// backdrop in it (the quit draws the root without the material), so the live material shows through where only
/// the backdrop showed, blur and art included.
///
/// Chrome shows a saved capture of the first restored tab the same way and removes it once the live page paints
/// (chrome/android/java/src/org/chromium/chrome/browser/paint_preview/StartupPaintPreviewHelper.java).
///
/// The view draws nothing: its layer's contents are the decoded image at the window's backing scale, pinned to
/// the top-left corner (a window whose height changes keeps its titlebar and sidebar where the picture has them).
/// It takes no key. Hit tests pass through it to whatever is under it, but where ``LaunchPictureInput`` holds the
/// clicks on the picture: there a click on a point the picture still shows is its own.
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

    /// Whether a click at a point of the view waits on the picture (``LaunchPictureInput``); nil, the picture takes none.
    var takesClick: (@MainActor (CGPoint) -> Bool)?
    /// A mouse-down on the picture and its point in the view.
    var pressed: (@MainActor (NSEvent, CGPoint) -> Void)?
    var released: (@MainActor (NSEvent) -> Void)?

    /// Clicks reach the live views under the picture, but where the picture holds them.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard let takesClick, !isHidden else { return nil }
        return takesClick(superview.map { convert(point, from: $0) } ?? point) ? self : nil
    }

    /// The launch's first click often activates the app too: it is held like any other.
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { takesClick != nil }

    override public func mouseDown(with event: NSEvent) { press(event) }
    override public func rightMouseDown(with event: NSEvent) { press(event) }
    override public func otherMouseDown(with event: NSEvent) { press(event) }
    override public func mouseUp(with event: NSEvent) { released?(event) }
    override public func rightMouseUp(with event: NSEvent) { released?(event) }
    override public func otherMouseUp(with event: NSEvent) { released?(event) }
    // A drag or a scroll on the picture means nothing: no view under it is built to take it.
    override public func mouseDragged(with event: NSEvent) {}
    override public func rightMouseDragged(with event: NSEvent) {}
    override public func otherMouseDragged(with event: NSEvent) {}
    override public func scrollWheel(with event: NSEvent) {}

    private func press(_ event: NSEvent) {
        pressed?(event, convert(event.locationInWindow, from: nil))
    }
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
