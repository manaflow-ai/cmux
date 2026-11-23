import CoreGraphics
import CoreImage

/// Frosted over a still picture: the picture blurred once into an image the art layer shows as
/// its contents, in place of live Core Image layer filters on the art layer.
///
/// Leo, 2026-11-23, Frosted over Desktop Wallpaper on a 2x display: "it went only to the bottom
/// left", "as in it didnt fill the whole thing" (cmux#51381). A `CIAffineClamp` + `CIGaussianBlur`
/// layer filter on an aspect-filled picture under `layerContentsRedrawPolicy = .never` rendered
/// at one scale and anchored at the bottom-left origin on a Retina backing. A blurred image is
/// ordinary contents: the layer aspect-fills it over its whole bounds at any backing scale and any
/// size, through a live resize, like the sharp picture.
enum BackdropArtBlur {
    /// The blur in the output's own pixels: past it the output is shrunk, since a blurred picture
    /// keeps no detail finer than its blur, and the layer scales it up smoothly (a 6K wallpaper
    /// blurred by 20 points is a few hundred pixels across, not 80 MB).
    nonisolated static let sigmaPixels: CGFloat = 8
    /// How far the shown size may move before the blur is made again: the blur scales with the
    /// picture between, by at most this share.
    nonisolated static let refillTolerance: CGFloat = 0.2

    /// How the picture shows: points of the view per pixel of the picture, aspect-filled over
    /// `fill` points (the larger of the two ratios, as `resizeAspectFill`).
    nonisolated static func pointsPerPixel(width: Int, height: Int, fill: CGSize) -> CGFloat {
        guard width > 0, height > 0 else { return 1 }
        return max(fill.width / CGFloat(width), fill.height / CGFloat(height), .leastNonzeroMagnitude)
    }

    /// `image` blurred by `radius` points as it shows aspect-filled over `fill` points at `scale`
    /// pixels per point: clamped first, so the edges blur against their own pixels and keep no
    /// translucent rim, then cropped to the picture's whole extent. Its aspect ratio is the
    /// picture's, so the layer fills the same way; nil for no blur or a picture that did not render.
    nonisolated static func blurred(_ image: CGImage, radius: Int, fill: CGSize, scale: CGFloat) -> CGImage? {
        guard radius > 0, fill.width > 0, fill.height > 0, image.width > 0, image.height > 0 else { return nil }
        let perPixel = pointsPerPixel(width: image.width, height: image.height, fill: fill)
        // The radius in the picture's own pixels, then the shrink: never past the screen's pixels
        // or the picture's own, and small enough that the blur is about `sigmaPixels` across.
        let sourceSigma = CGFloat(radius) / perPixel
        let shrink = min(1, perPixel * max(scale, 1), sigmaPixels / sourceSigma)
        let width = max(Int((CGFloat(image.width) * shrink).rounded()), 1)
        let height = max(Int((CGFloat(image.height) * shrink).rounded()), 1)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let input = CIImage(cgImage: image)
        let scaled = shrink < 1
            ? input.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: Double(height) / Double(image.height),
                kCIInputAspectRatioKey: (Double(width) / Double(image.width)) / (Double(height) / Double(image.height)),
            ])
            : input
        let blurred = scaled.clampedToExtent().applyingGaussianBlur(sigma: Double(sourceSigma * shrink)).cropped(to: extent)
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // A context per blur, as the image store's texture pass: a blur is made when the picture,
        // its radius or its fill changes, not per frame.
        let context = CIContext(options: [.cacheIntermediates: false, .name: "cmux-next.backdrop.art-blur"])
        return context.createCGImage(blurred, from: extent, format: .RGBA8, colorSpace: space)
    }
}

/// A bitmap handed between a background task and the main actor (a decode, a blur).
// crash-allow: a CGImage is immutable once made; only its reference crosses, nothing mutates it.
nonisolated struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
}
