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

    func load(tokens: [String], workingDirectory: String?) async throws -> URL {
        try Task.checkCancellation()
        let resolver = RemoteTerminalPathResolver()
        let needsHome = tokens.contains {
            let token = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return token.hasPrefix("~") || token.hasPrefix("\"~") || token.hasPrefix("'~")
        }
        let home = needsHome ? try await provider.resolveHomePath() : nil
        let host = String(provider.destination.split(separator: "@").last ?? "")
        let candidates = resolver.candidates(
            tokens: tokens,
            workingDirectory: workingDirectory,
            homeDirectory: home,
            remoteHost: host
        )
        let identity = [provider.destination, provider.port.map(String.init) ?? "", provider.identityFile ?? ""]
            + provider.sshOptions
        let identityData = try JSONSerialization.data(withJSONObject: identity)
        let namespace = SHA256.hash(data: identityData).map { String(format: "%02x", $0) }.joined()
        for path in candidates {
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
        throw FileExplorerError.providerUnavailable
    }
}
