import AppKit
import CoreImage

/// Caches rendered backdrop textures for the lifetime of one window backdrop view.
@MainActor
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
