import AppKit
import CoreImage

/// Applies one Core Image texture pass before AppKit paints a backdrop.
struct BackdropTextureRenderer {
    let context: CIContext

    func render(_ source: NSImage, texture: BackdropTexture) -> NSImage? {
        guard texture.filter != .none, texture.strength > 0,
              let tiff = source.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let input = CIImage(bitmapImageRep: bitmap) else { return source }

        let output: CIImage?
        switch texture.filter {
        case .none:
            output = input
        case .orderedDither4x4, .orderedDither8x8:
            output = dither(input, strength: texture.strength,
                            matrixSize: texture.filter == .orderedDither4x4 ? 4 : 8)
        case .halftone:
            output = halftone(input, strength: texture.strength)
        case .grain:
            output = grain(input, strength: texture.strength)
        }
        guard let output else { return source }
        // Keep the Core Image representation lazy. Material application runs
        // on AppKit's main actor; forcing a CGImage here performs a synchronous
        // GPU readback and blocks that actor.
        let image = NSImage(size: source.size)
        image.addRepresentation(NSCIImageRep(ciImage: output.cropped(to: input.extent)))
        return image
    }

    /// Sets key only when the filter declares it. CIFilter raises an
    /// Objective-C exception for an unknown key.
    private static func set(_ value: Any, _ key: String, on filter: CIFilter) {
        guard filter.inputKeys.contains(key) else { return }
        filter.setValue(value, forKey: key)
    }

    private func dither(_ input: CIImage, strength: Double, matrixSize: Int) -> CIImage? {
        guard let filter = CIFilter(name: "CIDither") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        Self.set(strength, "inputIntensity", on: filter)
        // CIDither has no matrix size on current macOS releases. Keep this
        // guarded so older/newer filter variants remain safe.
        Self.set(matrixSize, "inputMatrixSize", on: filter)
        return filter.outputImage ?? input
    }

    private func halftone(_ input: CIImage, strength: Double) -> CIImage? {
        guard let filter = CIFilter(name: "CICMYKHalftone") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        Self.set(2 + CGFloat(10 * (1 - strength)), "inputWidth", on: filter)
        Self.set(0, "inputAngle", on: filter)
        Self.set(0.7 + CGFloat(strength) * 0.3, "inputSharpness", on: filter)
        return filter.outputImage?.cropped(to: input.extent) ?? input
    }

    private func grain(_ input: CIImage, strength: Double) -> CIImage? {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage,
              let color = CIFilter(name: "CIColorMatrix") else { return input }
        color.setValue(noise.cropped(to: input.extent), forKey: kCIInputImageKey)
        let amount = CGFloat(strength * 0.16)
        Self.set(CIVector(x: 0, y: 0, z: 0, w: amount), "inputAVector", on: color)
        Self.set(CIVector(x: 0.5, y: 0.5, z: 0.5, w: 0), "inputBiasVector", on: color)
        guard let grain = color.outputImage,
              let blend = CIFilter(name: "CIScreenBlendMode") else { return input }
        blend.setValue(grain, forKey: kCIInputImageKey)
        blend.setValue(input, forKey: kCIInputBackgroundImageKey)
        return blend.outputImage?.cropped(to: input.extent) ?? input
    }
}
