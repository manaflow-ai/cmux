public import CmuxCore
public import Foundation
internal import CmuxSettings
internal import CryptoKit

/// Mediates the cmuxd-remote release manifest and the local cache of
/// verified daemon binaries it indexes: fetches the live manifest from a
/// release, downloads + checksum-verifies binaries, and validates/places them
/// in the shared on-disk cache the separately-signed CLI also reads.
///
/// Faithful lift of the manifest/cache/download half of the legacy
/// `WorkspaceRemoteSessionController` bootstrap path. The embedded-manifest
/// read stays app-side (`Bundle.main` never crosses into the package); the
/// dev-only local `go build` fallback stays with the session controller.
///
/// Isolation design: stateless `Sendable` value (injected `FileManager` +
/// home directory only), so no actor is warranted; methods are synchronous
/// and blocking by contract because the caller is the session controller's
/// serial utility queue mid-bootstrap, which cannot await. The two network
/// calls bridge `URLSession`'s callbacks with a semaphore exactly like the
/// legacy code; converting them to `async` is deferred modernization for the
/// coordinator phase.
public struct RemoteDaemonManifestRepository: Sendable {
    /// Result of ``downloadBinary(entry:version:releaseURL:)``.
    public struct Download: Sendable {
        /// Final cached location of the verified binary.
        public let binaryURL: URL
        /// True when the embedded manifest's checksum was stale and the
        /// download was instead verified against the live release manifest
        /// (a newer nightly overwrote the shared release asset).
        public let usedLiveManifestChecksumFallback: Bool
    }

    // FileManager is documented thread-safe for these path-based operations;
    // scoping the escape hatch to the one property beats `@unchecked
    // Sendable` on the type.
    private nonisolated(unsafe) let fileManager: FileManager
    private let homeDirectory: URL

    /// Creates a repository rooted at `homeDirectory`'s cmux state cache.
    ///
    /// - Parameters:
    ///   - fileManager: Filesystem seam.
    ///   - homeDirectory: The user's home directory; composition roots pass
    ///     `FileManager.default.homeDirectoryForCurrentUser` so the app and
    ///     CLI agree on the cache path independently of `$HOME` overrides.
    public init(fileManager: FileManager = .default, homeDirectory: URL) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    /// The cache path for one version/platform daemon binary
    /// (`<state>/remote-daemons/<version>/<goOS>-<goArch>/cmuxd-remote`),
    /// creating the cache root directory if needed.
    ///
    /// Cached under the non-TCC cmux state directory (matching the CLI's
    /// `remoteDaemonCacheURL`) rather than Application Support, so the
    /// separately-signed CLI can read it on `cmux ssh` without tripping the
    /// macOS Sequoia "access data from other apps" prompt
    /// (https://github.com/manaflow-ai/cmux/issues/5146).
    public func cachedBinaryURL(version: String, goOS: String, goArch: String) throws -> URL {
        try cacheRoot()
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("cmuxd-remote", isDirectory: false)
    }

    /// Returns the cached binary for `entry` when it exists, matches the
    /// entry's checksum, and is executable; removes (and reports `nil` for) a
    /// stale or non-executable cache entry. Throws when the cache cannot be
    /// read.
    public func validatedCachedBinary(entry: WorkspaceRemoteDaemonManifest.Entry, version: String) throws -> URL? {
        let cacheURL = try cachedBinaryURL(version: version, goOS: entry.goOS, goArch: entry.goArch)
        guard fileManager.fileExists(atPath: cacheURL.path) else { return nil }
        let cachedSHA = try sha256Hex(forFile: cacheURL)
        if cachedSHA == entry.sha256.lowercased(),
           fileManager.isExecutableFile(atPath: cacheURL.path) {
            return cacheURL
        }
        try? fileManager.removeItem(at: cacheURL)
        return nil
    }

    /// Fetches the live manifest JSON from the release, returning nil on any
    /// failure (blocking; 15s request timeout, 20s overall wait).
    public func fetchManifest(releaseURL: String, version: String) -> WorkspaceRemoteDaemonManifest? {
        guard let manifestURL = URL(string: "\(releaseURL)/cmuxd-remote-manifest.json") else { return nil }
        let request = NSMutableURLRequest(url: manifestURL)
        request.timeoutInterval = 15
        request.setValue("cmux/\(version)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        let semaphore = DispatchSemaphore(value: 0)
        // Single-assignment hand-off signalled exactly once by the data-task
        // callback before the blocking wait returns (legacy bridge shape).
        nonisolated(unsafe) var resultData: Data?
        session.dataTask(with: request as URLRequest) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return }
            resultData = data
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20.0)
        session.finishTasksAndInvalidate()
        guard let data = resultData else { return nil }
        return try? JSONDecoder().decode(WorkspaceRemoteDaemonManifest.self, from: data)
    }

    /// Downloads `entry`'s binary, verifies its checksum (falling back to the
    /// live release manifest when the embedded checksum is stale), marks it
    /// executable, and atomically installs it at the cache path (blocking;
    /// 60s request timeout, 75s overall wait).
    public func downloadBinary(
        entry: WorkspaceRemoteDaemonManifest.Entry,
        version: String,
        releaseURL: String? = nil
    ) throws -> Download {
        guard let url = URL(string: entry.downloadURL) else {
            throw NSError(domain: "cmux.remote.daemon", code: 25, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon manifest has an invalid download URL",
            ])
        }

        let cacheURL = try cachedBinaryURL(version: version, goOS: entry.goOS, goArch: entry.goArch)
        try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let request = NSMutableURLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("cmux/\(version)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)

        let semaphore = DispatchSemaphore(value: 0)
        // Single-assignment hand-offs signalled exactly once by the
        // download-task callback before the blocking wait returns (legacy
        // bridge shape).
        nonisolated(unsafe) var downloadedURL: URL?
        nonisolated(unsafe) var downloadError: (any Error)?
        session.downloadTask(with: request as URLRequest) { localURL, response, error in
            defer { semaphore.signal() }
            if let error {
                downloadError = error
                return
            }
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                downloadError = NSError(domain: "cmux.remote.daemon", code: 26, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon download failed with HTTP \(httpResponse.statusCode)",
                ])
                return
            }
            downloadedURL = localURL
        }.resume()
        _ = semaphore.wait(timeout: .now() + 75.0)
        session.finishTasksAndInvalidate()

        if let downloadError {
            throw downloadError
        }
        guard let downloadedURL else {
            throw NSError(domain: "cmux.remote.daemon", code: 27, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon download did not produce a file",
            ])
        }

        var usedLiveManifestChecksumFallback = false
        let downloadedSHA = try sha256Hex(forFile: downloadedURL)
        if downloadedSHA != entry.sha256.lowercased() {
            // The embedded manifest's checksum doesn't match the downloaded binary.
            // This can happen when a newer nightly overwrites the shared release
            // asset after this build's manifest was embedded. As a fallback, fetch
            // the live manifest from the release and verify against that.
            if let releaseURL,
               let liveManifest = fetchManifest(releaseURL: releaseURL, version: version),
               let liveEntry = liveManifest.entry(goOS: entry.goOS, goArch: entry.goArch),
               downloadedSHA == liveEntry.sha256.lowercased() {
                usedLiveManifestChecksumFallback = true
            } else {
                throw NSError(domain: "cmux.remote.daemon", code: 28, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon checksum mismatch for \(entry.assetName)",
                ])
            }
        }

        let tempURL = cacheURL.deletingLastPathComponent()
            .appendingPathComponent(".\(cacheURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try? fileManager.removeItem(at: tempURL)
        try fileManager.moveItem(at: downloadedURL, to: tempURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
        try? fileManager.removeItem(at: cacheURL)
        try fileManager.moveItem(at: tempURL, to: cacheURL)
        return Download(
            binaryURL: cacheURL,
            usedLiveManifestChecksumFallback: usedLiveManifestChecksumFallback
        )
    }

    private func cacheRoot() throws -> URL {
        let cacheRoot = CmuxStateDirectory.url(homeDirectory: homeDirectory)
            .appendingPathComponent("remote-daemons", isDirectory: true)
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        return cacheRoot
    }

    private func sha256Hex(forFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
