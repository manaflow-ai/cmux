import AppKit
import CoreImage

/// A blurred copy of the art handed from the blurring task to the main actor.
// crash-allow: immutable CGImage is transferred from the detached blur to the main actor.
struct BlurredArt: @unchecked Sendable {
    let image: CGImage
}

extension WindowMaterialView {
    /// The longest side of a blurred copy, in pixels: a blur keeps no detail a larger one would show.
    nonisolated static let blurredArtLongestSide: CGFloat = 1024
    /// The size a blur is measured against before the view has one (a backdrop made at `.zero`).
    nonisolated static let blurFallbackSize = CGSize(width: 1440, height: 900)

    /// What the art layer draws for `image`: the picture itself, or under Frosted
    /// (``artBlurRadius`` above 0) a copy blurred once, which the layer aspect-fills like the
    /// sharp one. The art layer never carries Core Image filters: a clamped blur has no end, and
    /// Core Animation then drew the picture at its own pixel size from the bottom-left corner
    /// instead of filling the window (Leo, 2026-11-23: "ah, it went only to the bottom left").
    /// Until the copy is ready (off the main actor) the sharp picture shows, then fades into it.
    func artContents(_ image: NSImage?) -> Any? {
        guard let image else { return nil }
        guard artBlurRadius > 0 else { return image }
        if let blurred = blurredArt, blurred.source === image, blurred.radius == artBlurRadius { return blurred.image }
        blurArt(image, radius: artBlurRadius)
        return image
    }

    /// Blurs `image` off the main actor, then shows the copy if the art and radius are still these.
    private func blurArt(_ image: NSImage, radius: Int) {
        if let pending = pendingArtBlur, pending.source === image, pending.radius == radius { return }
        artBlurLoad?.cancel()
        pendingArtBlur = (image, radius)
        var rect = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        let sharp = BlurredArt(image: source)
        let size = bounds.width > 0 && bounds.height > 0 ? bounds.size : Self.blurFallbackSize
        artBlurLoad = Task { [weak self] in
            let blurred = await Task.detached(priority: .userInitiated) {
                Self.blurred(sharp, radius: radius, filling: size)
            }.value
            guard !Task.isCancelled, let self, let blurred else { return }
            self.pendingArtBlur = nil
            self.blurredArt = (image, radius, blurred.image)
            guard self.artImage === image, self.artBlurRadius == radius, let layer = self.artView.layer else { return }
            let from = layer.presentation()?.contents ?? layer.contents
            layer.contents = blurred.image
            if self.window?.isVisible == true, !Motion.reduceMotion {
                Motion.panes.set(layer, "contents", to: blurred.image, fade: .wallpaper, from: from)
            }
        }
    }

    /// `art` blurred by `radius` points as it shows aspect-filled into `size`, at most
    /// ``blurredArtLongestSide`` pixels on its longest side, its edges clamped (no dark rim) and
    /// cropped to the picture's own extent, so the layer's gravity fills the view with it.
    nonisolated static func blurred(_ art: BlurredArt, radius: Int, filling size: CGSize) -> BlurredArt? {
        let source = art.image
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = min(1, blurredArtLongestSide / CGFloat(max(source.width, source.height)))
        let small = CIImage(cgImage: source).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = small.extent.integral
        // Aspect fill: points on screen per pixel of the copy.
        let fill = max(size.width / extent.width, size.height / extent.height)
        let sigma = Double(radius) / Double(max(fill, 0.0001))
        let output = small.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        let context = CIContext(options: [.cacheIntermediates: false, .name: "cmux-next.backdrop.art-blur"])
        return context.createCGImage(output, from: extent).map(BlurredArt.init)
    }
}
