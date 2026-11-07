import CmuxTerminalCore
import CryptoKit
import Darwin
import Foundation

/// Downloads click-preview candidates through the same transport used by the SSH file explorer.
actor RemoteTerminalFilePreviewLoader {
    private let provider: SSHFileExplorerProvider
    private let cacheDirectory: URL
    private let fileManager: FileManager

    init(provider: SSHFileExplorerProvider, cacheDirectory: URL, fileManager: FileManager) {
        self.provider = provider
        self.cacheDirectory = cacheDirectory
        self.fileManager = fileManager
    }

    /// Downloads the first available candidate, querying directory metadata only when needed.
    ///
    /// - Parameters:
    ///   - tokens: Terminal path tokens in preferred order.
    ///   - workingDirectory: The terminal's reported directory. Relative tokens try it after the
    ///     live directory, because a shell can print paths relative to its own directory while
    ///     the foreground process runs elsewhere.
    ///   - liveWorkingDirectory: Reads the remote shell's current directory. It is consulted only for
    ///     relative tokens, because a reported directory can be the stale spawn directory.
    /// - Returns: An atomically published local copy of the remote file.
    /// - Throws: Cancellation, cache errors, or a preview error when no candidate can be downloaded.
    func load(
        tokens: [String],
        workingDirectory: String?,
        liveWorkingDirectory: (@MainActor @Sendable () async -> String?)? = nil
    ) async throws -> URL {
        try Task.checkCancellation()
        let resolver = RemoteTerminalPathResolver()
        var liveDirectory: String?
        var queriedLiveDirectory = false
        var home: String?
        var seenPaths = Set<String>()
        let host = String(provider.destination.split(separator: "@").last ?? "")
        let identity = [provider.destination, provider.port.map(String.init) ?? "", provider.identityFile ?? ""]
            + provider.sshOptions
        let identityData = try JSONSerialization.data(withJSONObject: identity)
        let namespace = SHA256.hash(data: identityData).map { String(format: "%02x", $0) }.joined()
        for token in tokens {
            try Task.checkCancellation()
            if !queriedLiveDirectory, let liveWorkingDirectory,
               resolver.needsWorkingDirectory(tokens: [token]) {
                queriedLiveDirectory = true
                if let live = await liveWorkingDirectory(), live.hasPrefix("/") {
                    liveDirectory = live
                }
            }
            try Task.checkCancellation()
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if home == nil, trimmed.hasPrefix("~") || trimmed.hasPrefix("\"~") || trimmed.hasPrefix("'~") {
                home = try await provider.resolveHomePath()
            }
            var candidates = resolver.candidates(
                tokens: [token], workingDirectory: liveDirectory ?? workingDirectory,
                homeDirectory: home, remoteHost: host
            )
            if let liveDirectory, let workingDirectory, liveDirectory != workingDirectory {
                candidates += resolver.candidates(
                    tokens: [token], workingDirectory: workingDirectory, homeDirectory: home, remoteHost: host
                )
            }
            for path in candidates where seenPaths.insert(path).inserted {
                try Task.checkCancellation()
                let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
                let directory = cacheDirectory.appendingPathComponent(namespace).appendingPathComponent(digest)
                try fileManager.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
                )
                let staging = directory.appendingPathComponent(UUID().uuidString + ".download")
                defer { try? fileManager.removeItem(at: staging) }
                do {
                    try await provider.downloadFile(path: path, to: staging)
                    try Task.checkCancellation()
                    let destination = directory.appendingPathComponent((path as NSString).lastPathComponent)
                    // Publish a complete file atomically; an existing preview never sees a partial download.
                    guard rename(staging.path, destination.path) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    return destination
                } catch {
                    try Task.checkCancellation()
                }
            }
        }
        throw FileExplorerError.remoteFileUnavailable
    }
}
