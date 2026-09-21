import Foundation

/// Transferred from a completed download to its read-only preview panel.
final class CloudFilePreviewLease: Sendable {
    let url: URL
    private let cache: CloudFilePreviewCache

    init(url: URL, cache: CloudFilePreviewCache) {
        self.url = url
        self.cache = cache
    }

    deinit {
        let url = url, cache = cache
        Task { await cache.release(url) }
    }
}
