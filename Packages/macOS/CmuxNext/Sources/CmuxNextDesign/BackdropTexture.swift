import AppKit
import CoreImage

/// The texture treatment applied once to a backdrop image when it is loaded.
public nonisolated struct BackdropTexture: Hashable, Sendable {
    /// The selected texture algorithm.
    public let filter: BackdropTextureFilter
    /// The filter strength, from none to full effect.
    public let strength: Double

    /// The quiet default for authored artwork.
    public static let `default` = Self(filter: .orderedDither4x4, strength: 0.12)

    /// Creates a texture treatment, clamping invalid strength values safely.
    ///
    /// - Parameters:
    ///   - filter: The algorithm to apply.
    ///   - strength: The effect intensity in the inclusive range 0...1.
    public init(filter: BackdropTextureFilter, strength: Double) {
        self.filter = filter
        self.strength = strength.isFinite ? min(max(strength, 0), 1) : (strength.sign == .plus ? 1 : 0)
    }

    /// A stable cache component for one treatment.
    public var id: String { "\(filter.rawValue):\(String(format: "%.3f", strength))" }
}

/// Caches rendered backdrop textures for the lifetime of one window backdrop view.
final class BackdropTextureCache {
    private struct Key: Hashable {
        let source: String
        let texture: BackdropTexture
    }

    private var values: [Key: NSImage] = [:]
    private let context = CIContext(options: [.cacheIntermediates: true])
    private(set) var renderCount = 0

    /// Returns a cached rendering, generating it only for a new source and plan.
    func image(for sourceID: String, source: NSImage, texture: BackdropTexture) -> NSImage? {
        let key = Key(source: sourceID, texture: texture)
        if let cached = values[key] { return cached }
        let rendered = BackdropTextureRenderer(context: context).render(source, texture: texture) ?? source
        values[key] = rendered
        renderCount += 1
        return rendered
    }
}

/// Performs one Core Image texture pass before AppKit paints a backdrop.
private struct BackdropTextureRenderer {
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

    /// Sets `key` only when `filter` declares it. CIFilter raises an
    /// Objective-C exception (an app crash) for a key it does not have,
    /// and the key set differs between filters and macOS releases.
    static func set(_ value: Any, _ key: String, on filter: CIFilter) {
        guard filter.inputKeys.contains(key) else { return }
        filter.setValue(value, forKey: key)
    }

    private func dither(_ input: CIImage, strength: Double, matrixSize: Int) -> CIImage? {
        guard let filter = CIFilter(name: "CIDither") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        Self.set(strength, "inputIntensity", on: filter)
        // CIDither has no matrix size: the key is skipped (both sizes render
        // alike) until an ordered Bayer pass replaces it.
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
