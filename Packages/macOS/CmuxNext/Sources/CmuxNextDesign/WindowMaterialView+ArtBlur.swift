import AppKit
import CoreImage

/// Frosted over a picture: the picture the art layer shows is a blurred copy of it, made off the
/// main actor once per picture and radius. The layer keeps its aspect fill and carries no Core
/// Image filter: with a filter chain on the aspect-filled art layer, the picture drew in the
/// window's bottom-left (Leo, 2026-11-23: "ah, it went only to the bottom left. lawrence
/// encountered this issue before").
nonisolated enum ArtBlur {
    /// A blurred copy and what it was made from.
    struct Copy {
        /// The picture it blurs, held so an identity never matches a later picture at its address.
        var source: NSImage
        var pixelRadius: Int
        var image: CGImage
    }

    /// The blur radius in the picture's pixels for `radius` points of a `bounds`-sized view that
    /// aspect-fills it, so the blur looks the same at any picture size.
    static func pixelRadius(_ radius: Int, width: Int, height: Int, in bounds: CGSize) -> Int {
        guard width > 0, height > 0 else { return radius }
        // Points per picture pixel under aspect fill; with no size yet, one pixel per point.
        let fill = bounds.width > 0 && bounds.height > 0
            ? max(bounds.width / CGFloat(width), bounds.height / CGFloat(height)) : 1
        return max(1, Int((CGFloat(radius) / fill).rounded()))
    }

    /// `picture` blurred by `pixelRadius` pixels, clamped first so the edge pixels (not
    /// transparency) blur in past the edge and the picture keeps no translucent rim; nil when Core
    /// Image fails.
    /// It runs once per picture and radius, so its context is its own.
    @concurrent static func blurred(_ picture: CGImage, pixelRadius: Int) async -> CGImage? {
        let input = CIImage(cgImage: picture)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: Double(pixelRadius)).cropped(to: input.extent)
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: input.extent)
    }
}

extension WindowMaterialView {
    /// What the art layer shows for `image`: the picture, or under Frosted its blurred copy. A
    /// copy not made yet is made off the main actor (``artBlurJob``) and replaces the picture when
    /// it is ready; until then the layer keeps what it shows, or shows the picture.
    func artContents(for image: NSImage?) -> Any? {
        guard let image else { return nil }
        guard artBlurRadius > 0, let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let pixelRadius = ArtBlur.pixelRadius(artBlurRadius, width: source.width, height: source.height, in: bounds.size)
        if let copy = blurredArt, copy.source === image, copy.pixelRadius == pixelRadius { return copy.image }
        artBlurJob?.cancel()
        artBlurJob = Task { [weak self] in
            guard let blurred = await ArtBlur.blurred(source, pixelRadius: pixelRadius), !Task.isCancelled,
                  let self, self.artImage === image, self.artBlurRadius > 0 else { return }
            self.blurredArt = ArtBlur.Copy(source: image, pixelRadius: pixelRadius, image: blurred)
            self.artView.layer?.contents = blurred
            self.noteGlassSourceChange()
        }
        // A blurred copy of the same picture showing now stays until the new one is ready.
        if let copy = blurredArt, copy.source === image { return copy.image }
        return image
    }
}
