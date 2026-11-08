import Foundation

/// Transferred from a completed download to its read-only preview panel.
final class CloudFilePreviewLease: Sendable {
    let url: URL
    let remotePath: String
    let remoteIdentity: String
    private let cache: CloudFilePreviewCache

    init(url: URL, remotePath: String, remoteIdentity: String, cache: CloudFilePreviewCache) {
        self.url = url
        self.remotePath = remotePath
        self.remoteIdentity = remoteIdentity
        self.cache = cache
    }

    deinit {
        let url = url, cache = cache
        Task { await cache.release(url) }
    }

    func refresh(using provider: any RemoteFileExplorerProvider) async throws {
        try await cache.refresh(self, provider: provider)
    }
}
