import AppKit
import CoreImage

/// Frosted over a still picture: the picture is blurred once, off the main actor, cropped to its own
/// size, and that blurred picture is the art layer's contents. No live Core Image filter sits on the
/// art layer: a clamp's infinite extent under a layer filter, on a 2x display, drew the blurred art
/// at its first size and scale from the bottom-left corner (Leo, 2026-11-23, Frosted over Desktop
/// Wallpaper: "it went only to the bottom left"; Lawrence saw it before, cmux#51381). The video and
/// living wallpaper keep their live filters: they change every frame.
extension WindowMaterialView {
    /// The picture the art layer shows for `image`: `image` itself without a blur, its blurred copy
    /// once made (kept for the same picture and radius), or nil while that copy is being made (the
    /// layer keeps what it shows; ``artBlur`` then fades the blurred copy in).
    func artContents(for image: NSImage?) -> Any? {
        guard let image, artBlurRadius > 0 else { return image }
        if let kept = blurredArt, kept.source === image, kept.radius == artBlurRadius { return kept.image }
        blurArt(image)
        return nil
    }

    /// Sets the art layer to show `image`: its blurred copy when ready, else what shows now while
    /// one is made, else `image` sharp (nothing shows yet).
    func showArtContents(_ image: NSImage?) {
        guard let layer = artView.layer else { return }
        guard let image else { layer.contents = nil; return }
        if let contents = artContents(for: image) {
            layer.contents = contents
        } else if layer.contents == nil {
            layer.contents = image
        }
    }

    /// Makes `image`'s blurred copy off the main actor, then shows it if `image` and the radius are
    /// still the ones asked for. One blur runs at a time; a new picture or radius replaces it.
    private func blurArt(_ image: NSImage) {
        let radius = artBlurRadius
        if let pending = artBlurPending, pending.source === image, pending.radius == radius { return }
        guard let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let pixels = Self.imagePixels(ofPoints: CGFloat(radius), width: picture.width, height: picture.height,
                                      filling: artFillSize)
        artBlur?.cancel()
        artBlurPending = (image, radius)
        artBlur = Task { [weak self] in
            let blurred = await Self.blur(picture, radius: pixels)
            guard !Task.isCancelled, let self, self.artImage === image, self.artBlurRadius == radius else { return }
            self.artBlurPending = nil
            guard let blurred else { return }
            self.blurredArt = (image, radius, blurred)
            self.fadeInBlurredArt(blurred)
        }
    }

    /// Crossfades the art layer to its blurred copy (`MotionFade.wallpaper`) when on screen and
    /// Reduce Motion is off; otherwise shows it at once.
    private func fadeInBlurredArt(_ blurred: CGImage) {
        guard let layer = artView.layer else { return }
        let from = layer.presentation()?.contents ?? layer.contents
        guard from != nil, window?.isVisible == true || crossfadesOffScreen, !Motion.reduceMotion else {
            layer.contents = blurred
            return
        }
        layer.contents = blurred
        Motion.panes.set(layer, "contents", to: blurred, fade: .wallpaper, from: from)
    }

    /// The size the art fills: the view's, or its screen's before the view has a size (a window's
    /// backdrop is made at `.zero` and sized by its root afterwards).
    private var artFillSize: CGSize {
        if bounds.width >= 1, bounds.height >= 1 { return bounds.size }
        return (window?.screen ?? NSScreen.main)?.frame.size ?? CGSize(width: 1440, height: 900)
    }

    /// `points` on screen as pixels of a `width` x `height` picture aspect-filled into `size`.
    nonisolated static func imagePixels(ofPoints points: CGFloat, width: Int, height: Int, filling size: CGSize) -> CGFloat {
        guard width > 0, height > 0, size.width > 0, size.height > 0 else { return points }
        // Aspect fill: points per picture pixel is the larger of the two ratios.
        let pointsPerPixel = max(size.width / CGFloat(width), size.height / CGFloat(height))
        return points / pointsPerPixel
    }

    /// `picture` blurred by `radius` of its own pixels, the same size as `picture`: clamped first so
    /// the edges read their own pixels, not transparency, then cropped back to the picture.
    @concurrent nonisolated static func blur(_ picture: CGImage, radius: CGFloat) async -> CGImage? {
        guard radius > 0 else { return nil }
        let input = CIImage(cgImage: picture)
        let extent = input.extent
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: Double(radius)).cropped(to: extent)
        // A context of its own, as the image store's textures make: a blur runs once per picture or radius.
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: extent)
    }
}
