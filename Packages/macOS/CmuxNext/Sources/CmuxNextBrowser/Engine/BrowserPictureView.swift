import AppKit

/// A page's picture, shown only while in a window: a hibernated tab's placeholder
/// (`HibernatedBrowserTab`), and the stand-in over a woken page until it paints
/// (`BrowserWakeStandIn`). A compressed picture decodes when drawn (10 to 30 ms for a full page, a
/// dropped frame on the switch to the tab), so it is decoded off the main thread first; the
/// decoded pixels are held only while in a window.
final class BrowserPictureView: NSImageView {
    private let picture: @MainActor () -> CGImage?
    private var decoding: Task<Void, Never>?

    init(picture: @escaping @MainActor () -> CGImage?) {
        self.picture = picture
        super.init(frame: .zero)
        imageScaling = .scaleAxesIndependently
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        decoding?.cancel()
        image = nil
        guard newWindow != nil, let picture = picture() else { return }
        decoding = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) { Self.decoded(picture) }.value
            guard let self, !Task.isCancelled else { return }
            image = NSImage(cgImage: decoded, size: .zero)
        }
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
