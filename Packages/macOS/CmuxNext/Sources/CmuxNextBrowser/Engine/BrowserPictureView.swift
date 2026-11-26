import AppKit

/// A page's picture, shown only while in a window: a hibernated tab's placeholder
/// (`HibernatedBrowserTab`), and the stand-in over a woken page until it paints
/// (`BrowserWakeStandIn`). A compressed picture decodes when drawn (10 to 30 ms for a full page, a
/// dropped frame on the switch to the tab), so it is decoded off the main thread first; the
/// decoded pixels are held only while in a window. A view made from pixels already decoded
/// (`init(decoded:)`: a wake stand-in taking over from the shown placeholder) shows them from its
/// first frame and keeps them for its short life: decoding again would leave it empty for the
/// first frames, the blank frame the stand-in exists to remove.
///
/// The picture is drawn top-left at its own size, one picture pixel per window backing pixel, never
/// stretched to the pane, as a Chromium page shows its last frame while its pane changes size and as
/// an agent pane draws its launch image (`PaneContentView.showLaunchImage`). Stretched to the pane
/// (cmux#57419), a picture taken at another pane size drew the page's text at the wrong size, and a
/// picture with fewer pixels than the pane (a 640 px hover card thumbnail) drew it blurry until the
/// page painted.
final class BrowserPictureView: NSView {
    private let picture: @MainActor () -> CGImage?
    /// Pixels decoded before the view was made; shown at once and never dropped.
    private let ready: CGImage?
    private var decoding: Task<Void, Never>?
    /// The decoded pixels the view shows now; nil while it is not in a window or still decoding.
    private(set) var decodedPicture: CGImage?
    /// Called each time the view, in a window, got its decoded pixels (they draw in the next frame):
    /// a hibernated tab's wake is timed to it (`HibernationWakes` `picture_ms`).
    var onShown: (@MainActor () -> Void)?

    init(picture: @escaping @MainActor () -> CGImage?) {
        self.picture = picture
        ready = nil
        super.init(frame: .zero)
        configureLayer()
    }

    /// A view showing `decoded` (pixels already drawn into a bitmap) from its first frame, in or out of a window.
    init(decoded: CGImage) {
        picture = { decoded }
        ready = decoded
        super.init(frame: .zero)
        configureLayer()
        show(decoded)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configureLayer() {
        wantsLayer = true
        // The layer's contents are the picture; AppKit never redraws over them.
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .topLeft
        layer?.contentsScale = pixelsPerPoint
    }

    /// The window's backing scale: a page picture holds the device pixels of the page area it was taken of.
    /// Out of a window, the main screen's (2 when none).
    var pixelsPerPoint: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    override var isOpaque: Bool { false }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard ready == nil else { return }
        decoding?.cancel()
        decodedPicture = nil
        layer?.contents = nil
        guard newWindow != nil, let picture = picture() else { return }
        decoding = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) { Self.decoded(picture) }.value
            guard let self, !Task.isCancelled else { return }
            show(decoded)
            onShown?()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = pixelsPerPoint
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = pixelsPerPoint
    }

    private func show(_ decoded: CGImage) {
        decodedPicture = decoded
        layer?.contentsScale = pixelsPerPoint
        layer?.contents = decoded
    }

    /// `image` drawn into a bitmap of its size and color space, keeping its alpha if it has one
    /// (a page with a transparent background).
    private nonisolated static func decoded(_ image: CGImage) -> CGImage {
        let opaque = [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}
