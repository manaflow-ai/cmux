import Foundation

/// Transferred from a completed download to its read-only preview panel.
final class CloudFilePreviewLease: Sendable {
    let url: URL
    let remotePath: String
    private let cache: CloudFilePreviewCache

    init(url: URL, remotePath: String, cache: CloudFilePreviewCache) {
        self.url = url
        self.remotePath = remotePath
        self.cache = cache
    }

    deinit {
        let url = url, cache = cache
        Task { await cache.release(url) }
    }
}
