import AppKit

/// Owns a renderer and a bounded raster cache for one icon-view hierarchy.
@MainActor
public final class CmuxResolvedIconRenderContext {
    private typealias Entry = (
        image: NSImage,
        appearance: NSAppearance,
        assetBundle: Bundle?
    )

    private let renderer = CmuxResolvedIconRenderer()
    private let limit: Int
    private var entries: [CmuxResolvedIconReusableRenderKey: Entry] = [:]
    private var insertionOrder: [CmuxResolvedIconReusableRenderKey] = []

    /// Creates an isolated render owner with a bounded reusable-image cache.
    public init(cacheLimit: Int = 128) {
        precondition(cacheLimit > 0)
        self.limit = cacheLimit
    }

    func render(
        for request: CmuxResolvedIconRequest,
        appearance: NSAppearance,
        renderKey: CmuxResolvedIconRenderKey
    ) -> Result<NSImage, CmuxResolvedIconRenderFailure> {
        if let reusableKey = renderKey.reusableKey,
           let cachedImage = image(for: reusableKey, matching: renderKey) {
            return .success(cachedImage)
        }

        let result = renderer.render(for: request, appearance: appearance)
        if case .success(let image) = result, let reusableKey = renderKey.reusableKey {
            insert(image, for: reusableKey, renderKey: renderKey)
        }
        return result
    }

    private func image(
        for key: CmuxResolvedIconReusableRenderKey,
        matching renderKey: CmuxResolvedIconRenderKey
    ) -> NSImage? {
        guard let entry = entries[key],
              entry.appearance === renderKey.appearance,
              renderKey.matchesAssetBundle(entry.assetBundle) else {
            return nil
        }
        return entry.image
    }

    private func insert(
        _ image: NSImage,
        for key: CmuxResolvedIconReusableRenderKey,
        renderKey: CmuxResolvedIconRenderKey
    ) {
        guard entries[key] == nil else { return }
        if entries.count >= limit, let oldestKey = insertionOrder.first {
            insertionOrder.removeFirst()
            entries.removeValue(forKey: oldestKey)
        }
        entries[key] = (
            image: image,
            appearance: renderKey.appearance,
            assetBundle: renderKey.assetBundle
        )
        insertionOrder.append(key)
    }
}
