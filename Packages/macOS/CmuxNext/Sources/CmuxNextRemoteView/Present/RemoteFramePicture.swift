public import AppKit
import VideoToolbox

extension RemoteDecodedFrame {
    /// This frame as a picture (a hidden remote tab's last frame, kept when it is discarded),
    /// converted off the main thread.
    @concurrent public nonisolated func picture() async -> CGImage? {
        var image: CGImage?
        // SAFETY: VideoToolbox writes one +1 image to the local `image`, live for the call.
        guard unsafe VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image) == noErr else { return nil }
        return image
    }
}

extension RemoteVideoView {
    /// `host` as drawn, with `frame` (this view's last frame) where this view shows it: a video
    /// layer is not drawn by `cacheDisplay`, so the bitmap alone has no stream. Same size and
    /// layout as the pane, so a picture of it lines up with the pane it stands in for. Nil when
    /// `host` cannot be drawn (no size).
    package func composite(_ frame: CGImage, in host: NSView) -> CGImage? {
        // sync-layout: cacheDisplay below draws the laid-out host.
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let chrome = rep.cgImage, host.bounds.width > 0, host.bounds.height > 0,
              let context = CGContext(data: nil, width: chrome.width, height: chrome.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: chrome.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let pixels = CGRect(x: 0, y: 0, width: chrome.width, height: chrome.height)
        context.draw(chrome, in: pixels)
        if let geometry {
            // The image rect in `host`'s points, then in the bitmap's pixels (origin bottom left).
            let shown = host.convert(geometry.imageRect, from: self)
            let scale = CGFloat(chrome.width) / host.bounds.width
            let bottom = host.isFlipped ? host.bounds.height - shown.maxY : shown.minY
            context.draw(frame, in: CGRect(x: shown.minX * scale, y: bottom * scale, width: shown.width * scale, height: shown.height * scale))
        }
        return context.makeImage()
    }
}
