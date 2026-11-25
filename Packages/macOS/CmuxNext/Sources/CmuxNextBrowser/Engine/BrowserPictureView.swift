import AppKit

/// A page's picture, shown only while in a window: a hibernated tab's placeholder
/// (`HibernatedBrowserTab`), and the stand-in over a woken page until it paints
/// (`BrowserWakeStandIn`). A compressed picture decodes when drawn (10 to 30 ms for a full page, a
/// dropped frame on the switch to the tab), so it is decoded off the main thread first; the
/// decoded pixels are held only while in a window. A view made from pixels already decoded
/// (`init(decoded:)`: a wake stand-in taking over from the shown placeholder) shows them from its
/// first frame and keeps them for its short life: decoding again would leave it empty for the
/// first frames, the blank frame the stand-in exists to remove.
final class BrowserPictureView: NSImageView {
    private let picture: @MainActor () -> CGImage?
    /// Pixels decoded before the view was made; shown at once and never dropped.
    private let ready: CGImage?
    private var decoding: Task<Void, Never>?
    /// The decoded pixels the view shows now; nil while it is not in a window or still decoding.
    private(set) var decodedPicture: CGImage?

    init(picture: @escaping @MainActor () -> CGImage?) {
        self.picture = picture
        ready = nil
        super.init(frame: .zero)
        imageScaling = .scaleAxesIndependently
        wantsLayer = true
    }

    /// A view showing `decoded` (pixels already drawn into a bitmap) from its first frame, in or out of a window.
    init(decoded: CGImage) {
        picture = { decoded }
        ready = decoded
        super.init(frame: .zero)
        imageScaling = .scaleAxesIndependently
        wantsLayer = true
        show(decoded)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard ready == nil else { return }
        decoding?.cancel()
        decodedPicture = nil
        image = nil
        guard newWindow != nil, let picture = picture() else { return }
        decoding = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) { Self.decoded(picture) }.value
            guard let self, !Task.isCancelled else { return }
            show(decoded)
        }
    }

    private func show(_ decoded: CGImage) {
        decodedPicture = decoded
        image = NSImage(cgImage: decoded, size: .zero)
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
