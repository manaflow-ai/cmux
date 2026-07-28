import AppKit

/// Bounded cache for resolved icon rasters shared by icon views.
@MainActor
final class CmuxResolvedIconRenderCache {
    private typealias Entry = (
        image: NSImage,
        appearance: NSAppearance,
        assetBundle: Bundle?
    )

    private let limit: Int
    private var entries: [CmuxResolvedIconReusableRenderKey: Entry] = [:]
    private var insertionOrder: [CmuxResolvedIconReusableRenderKey] = []

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    func image(
        for key: CmuxResolvedIconReusableRenderKey,
        matching renderKey: CmuxResolvedIconRenderKey
    ) -> NSImage? {
        guard let entry = entries[key],
              entry.appearance === renderKey.appearance,
              bundlesMatch(entry.assetBundle, renderKey.assetBundle) else {
            return nil
        }
        return entry.image
    }

    func insert(
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

private func bundlesMatch(_ lhs: Bundle?, _ rhs: Bundle?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none):
        return true
    case let (lhs?, rhs?):
        return lhs === rhs
    default:
        return false
    }
}
