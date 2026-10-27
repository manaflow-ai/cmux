public import AppKit
public import CmuxNextDesign
public import Foundation

/// The front window's saved picture (``WindowPictureStore``) as one layer: the launch's first frame is the window
/// at its saved frame, its live `WindowMaterialView`, and this view over it (p08-startup-059). The picture has no
/// backdrop in it (the quit draws the root without the material), so the live material shows through where only
/// the backdrop showed, blur and art included.
///
/// Chrome shows a saved capture of the first restored tab the same way and removes it once the live page paints
/// (chrome/android/java/src/org/chromium/chrome/browser/paint_preview/StartupPaintPreviewHelper.java).
///
/// The view draws nothing: its picture layer's contents are the decoded image at the picture's own scale (its pixels
/// per point at the quit), pinned to the top-left corner and never stretched (a window whose height changes keeps
/// its titlebar and sidebar where the picture has them). The view's own layer carries no pixels: AppKit sets a
/// backing layer's scale to the window's, and its mask is the regions' (``LaunchPictureRegions``). The picture
/// layer's mask leaves out ``cut``, the regions whose layout changed since the quit
/// (``WindowPictureMeta/staleAreas(_:size:)``): the live material shows there until the live view is built.
/// It takes no key. Hit tests pass through it to whatever is under it, but where ``LaunchPictureInput`` holds the
/// clicks on the picture (p08-startup-061): there a click on a point the picture still holds is its own, in a cut
/// area too (its region is not built yet).
///
/// ```swift
/// let picture = LaunchPictureView(image: front.image, scale: front.meta.scale, cut: areas)
/// picture.frame = window.contentView!.bounds
/// ```
public final class LaunchPictureView: NSView {
    /// The picture, `scale` pixels per point.
    public let image: CGImage
    public let scale: CGFloat
    /// The parts of the picture that never show, in points from its top-left corner, not overlapping.
    public let cut: [CGRect]
    /// The layer that shows the picture's pixels, the only sublayer of the view's layer.
    let pictureLayer = CALayer()
    private let cutMask = CAShapeLayer()

    public init(image: CGImage, scale: CGFloat, cut: [CGRect] = []) {
        self.image = image
        self.scale = scale > 0 ? scale : 1
        self.cut = cut
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(image.width) / self.scale, height: CGFloat(image.height) / self.scale))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let still: [String: any CAAction] = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "path": NSNull(), "contents": NSNull()]
        pictureLayer.actions = still
        cutMask.actions = still
        cutMask.fillRule = .evenOdd
        cutMask.fillColor = CGColor(gray: 0, alpha: 1)
        pictureLayer.contents = image
        pictureLayer.contentsScale = self.scale
        pictureLayer.contentsGravity = .topLeft
        pictureLayer.masksToBounds = true
        pictureLayer.mask = cut.isEmpty ? nil : cutMask
        needsDisplay = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var wantsUpdateLayer: Bool { true }
    override public var isOpaque: Bool { false }

    override public func updateLayer() {
        place()
    }

    /// A resize moves the picture layer and its cut in the same frame, with no implicit animation.
    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    /// The picture layer over the view's bounds and the cut at its place from the top.
    private func place() {
        guard let layer else { return }
        if pictureLayer.superlayer !== layer { layer.addSublayer(pictureLayer) }
        pictureLayer.frame = bounds
        guard !cut.isEmpty else { return }
        cutMask.frame = pictureLayer.bounds
        let shown = CGMutablePath()
        shown.addRect(pictureLayer.bounds)
        for area in cut {
            let placed = Self.layerRect(area, in: pictureLayer.bounds, flipped: isFlipped)
            if !placed.isEmpty { shown.addRect(placed) }
        }
        cutMask.path = shown
    }

    /// `area`, in points from the picture's top-left corner, in a layer over `bounds`, clipped to it (empty outside
    /// it): the picture is pinned to the top, which is the layer's maximum y unless it is `flipped`.
    nonisolated static func layerRect(_ area: CGRect, in bounds: CGRect, flipped: Bool) -> CGRect {
        let placed = flipped ? area : CGRect(x: area.minX, y: bounds.height - area.maxY, width: area.width, height: area.height)
        let clipped = placed.offsetBy(dx: bounds.minX, dy: bounds.minY).intersection(bounds)
        return clipped.isNull ? .zero : clipped
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

extension WindowPictureStore.ShownPicture {
    /// The picture's pixels per point as the quit drew it (``LaunchPictureView/scale``).
    public var scale: CGFloat { picture.meta.scale > 0 ? CGFloat(picture.meta.scale) : 1 }

    /// The parts of the picture its changed regions cut out (``LaunchPictureView/cut``); nil when nothing of it is
    /// still right, so the window takes today's path (``WindowPictureMeta/staleAreas(_:size:)``).
    public var cut: [CGRect]? {
        picture.meta.staleAreas(stale, size: CGSize(width: CGFloat(picture.image.width) / scale, height: CGFloat(picture.image.height) / scale))
    }

    /// The launch marks of the cut regions, `launch_picture_stale.<region>`, in a fixed order.
    public var staleMarks: [String] { stale.map { "launch_picture_stale.\($0.rawValue)" }.sorted() }

    /// The launch regions the shown picture still lies over (``LaunchPicturePhase/show(_:scale:cut:covering:in:scope:present:startup:build:)``):
    /// a cut region's views fade in on their own, as on today's path.
    public var covered: Set<LaunchRegion> {
        stale.reduce(into: Set(LaunchRegion.allCases)) { $0.subtract($1.launchRegions) }
    }
}

extension WindowPictureMeta.Region.Kind {
    /// The launch regions whose views lie under this part of the picture: the content area holds the tab strips
    /// with the panes.
    public var launchRegions: Set<LaunchRegion> {
        switch self {
        case .sidebar: [.sidebar]
        case .pane: [.tabs, .pane]
        }
    }
}
