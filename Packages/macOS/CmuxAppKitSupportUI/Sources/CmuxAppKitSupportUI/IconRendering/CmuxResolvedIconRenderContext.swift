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
    ///
    /// Nonpositive limits disable cross-view caching while preserving rendering.
    public init(cacheLimit: Int = 128) {
        self.limit = max(0, cacheLimit)
    }

    func render(
        for request: CmuxResolvedIconRequest,
        appearance: NSAppearance,
        renderKey: CmuxResolvedIconRenderKey,
        bypassCache: Bool = false
    ) -> Result<NSImage, CmuxResolvedIconRenderFailure> {
        guard limit > 0 else {
            return renderer.render(for: request, appearance: appearance)
        }

        if !bypassCache,
           let reusableKey = renderKey.reusableKey,
           let cachedImage = image(for: reusableKey, matching: renderKey) {
            return .success(cachedImage)
        }

        let result = renderer.render(for: request, appearance: appearance)
        if case .success(let image) = result, let reusableKey = renderKey.reusableKey {
            insert(
                image,
                for: reusableKey,
                renderKey: renderKey,
                replacingExisting: bypassCache
            )
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
        renderKey: CmuxResolvedIconRenderKey,
        replacingExisting: Bool
    ) {
        let entry: Entry = (
            image: image,
            appearance: renderKey.appearance,
            assetBundle: renderKey.assetBundle
        )
        if entries[key] != nil {
            if replacingExisting {
                entries[key] = entry
            }
            return
        }
        if entries.count >= limit, let oldestKey = insertionOrder.first {
            insertionOrder.removeFirst()
            entries.removeValue(forKey: oldestKey)
        }
        entries[key] = entry
        insertionOrder.append(key)
    }
}
