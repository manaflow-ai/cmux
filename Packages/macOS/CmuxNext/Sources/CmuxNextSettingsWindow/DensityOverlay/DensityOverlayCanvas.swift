import AppKit
import CmuxNextDesign

/// What the Density Overlay Playground's canvas draws: a value read off ``DensityOverlayModel`` on each render.
struct DensityOverlayCanvasState: Equatable {
    var mode: DensityOverlayModel.Mode = .overlay
    var reference: CGImage?
    var live: CGImage?
    var flipShowsReference = false
    /// Points per image pixel: the model's zoom over 2, as the captures are 2x.
    var scale: CGFloat = 1
    var offset: CGPoint = .zero
    var opacity: CGFloat = 0.5
    /// The gap between the two images side by side.
    var spacing: CGFloat = 0
    /// The margin around the images.
    var padding: CGFloat = 0

    /// Images compare by identity (a capture is a new image), never by their pixels.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mode == rhs.mode && lhs.reference === rhs.reference && lhs.live === rhs.live
            && lhs.flipShowsReference == rhs.flipShowsReference && lhs.scale == rhs.scale && lhs.offset == rhs.offset
            && lhs.opacity == rhs.opacity && lhs.spacing == rhs.spacing && lhs.padding == rhs.padding
    }
}

/// The Density Overlay Playground's canvas, the scroll view's document: the reference and the live capture side by
/// side, one at a time (flip), or the reference over cmux at an offset with its opacity or a difference blend. Pixels
/// draw without smoothing, so the zoom is a loupe. A click anywhere on it runs ``onClick`` (the flip).
final class DensityOverlayCanvas: NSView {
    var state = DensityOverlayCanvasState() {
        didSet {
            guard state != oldValue else { return }
            setFrameSize(contentSize)
            needsDisplay = true
        }
    }

    /// A click on the canvas.
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) { onClick?() }

    /// The images' size with the padding on every side.
    var contentSize: NSSize {
        var width: CGFloat = 0, height: CGFloat = 0
        switch state.mode {
        case .sideBySide:
            let sizes = [state.reference, state.live].compactMap { $0.map(size) }
            width = sizes.map(\.width).max() ?? 0
            height = sizes.map(\.height).reduce(0, +) + state.spacing * CGFloat(max(sizes.count - 1, 0))
        case .flip:
            let image = state.flipShowsReference ? state.reference : state.live
            let shown = image.map(size) ?? .zero
            width = shown.width
            height = shown.height
        case .overlay, .difference:
            // As a ZStack: the larger of the two; the offset moves the reference without growing the canvas.
            let sizes = [state.reference, state.live].compactMap { $0.map(size) }
            width = sizes.map(\.width).max() ?? 0
            height = sizes.map(\.height).max() ?? 0
        }
        return NSSize(width: width + 2 * state.padding, height: height + 2 * state.padding)
    }

    private func size(_ image: CGImage) -> NSSize {
        NSSize(width: CGFloat(image.width) * state.scale, height: CGFloat(image.height) * state.scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        let origin = CGPoint(x: state.padding, y: state.padding)
        switch state.mode {
        case .sideBySide:
            var y = origin.y
            for image in [state.reference, state.live].compactMap({ $0 }) {
                draw(image, at: CGPoint(x: origin.x, y: y), in: context)
                y += size(image).height + state.spacing
            }
        case .flip:
            if let image = state.flipShowsReference ? state.reference : state.live { draw(image, at: origin, in: context) }
        case .overlay, .difference:
            // One transparency layer (the compositing group): the difference blends with cmux only, not the window.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            if let live = state.live { draw(live, at: origin, in: context) }
            if let reference = state.reference {
                context.saveGState()
                let difference = state.mode == .difference
                context.setAlpha(difference ? 1 : state.opacity)
                context.setBlendMode(difference ? .difference : .normal)
                draw(reference, at: CGPoint(x: origin.x + state.offset.x * state.scale, y: origin.y + state.offset.y * state.scale),
                     in: context)
                context.restoreGState()
            }
            context.endTransparencyLayer()
        }
    }

    /// Draws `image` with its top left at `point`, upright in this flipped view.
    private func draw(_ image: CGImage, at point: CGPoint, in context: CGContext) {
        let rect = CGRect(origin: point, size: size(image))
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}
