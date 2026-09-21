import Foundation

/// Owns only its newly-created preview files. Open panels hold leases, so no
/// scan, timeout, or another Files pane can delete a document still in use.
actor CloudFilePreviewCache {
    private let root: URL
    private let maximumEntries: Int
    private var entries: Set<URL> = []

    init(directory: URL = FileManager.default.temporaryDirectory, maximumEntries: Int = 32) {
        root = directory.appendingPathComponent("cmux-cloud-previews-" + UUID().uuidString, isDirectory: true)
        self.maximumEntries = maximumEntries
    }

    func materialize(path: String, provider: any RemoteFileExplorerProvider) async throws -> CloudFilePreviewLease {
        guard !ManagedFileTransferPolicy.isDisabled else {
            throw ManagedFileTransferPolicy.refusalError()
        }
        guard entries.count < maximumEntries else { throw FileExplorerError.previewCapacity }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filename = (path as NSString).lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else { throw FileExplorerError.providerUnavailable }
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        entries.insert(url)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try await provider.downloadFile(path: path, to: url)
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            return CloudFilePreviewLease(url: url, cache: self)
        } catch {
            release(url)
            throw error
        }
    }

    func release(_ url: URL) {
        guard entries.remove(url) != nil else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        if entries.isEmpty { try? FileManager.default.removeItem(at: root) }
    }
}
