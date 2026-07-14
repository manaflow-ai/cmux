public import CmuxCore
public import Foundation
internal import CmuxRemoteWorkspace
internal import CryptoKit

/// Production ``VPSDaemonArtifactProviding``: resolves binaries from the
/// app-embedded release manifest through the shared checksum-verified
/// download cache (``RemoteDaemonManifestRepository``), with the same
/// dev-only explicit-binary escape hatch the `cmux ssh` bootstrap honors
/// (`CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1` + `CMUX_REMOTE_DAEMON_BINARY`).
public struct VPSManifestArtifactProvider: VPSDaemonArtifactProviding {
    private let manifest: WorkspaceRemoteDaemonManifest?
    private let repository: RemoteDaemonManifestRepository
    private let fallbackVersion: String
    private let explicitBinaryURL: URL?

    /// Creates a provider.
    ///
    /// - Parameters:
    ///   - manifest: The embedded release manifest, or `nil` on dev builds.
    ///   - homeDirectory: Home directory anchoring the shared binary cache;
    ///     composition roots pass `FileManager.default.homeDirectoryForCurrentUser`.
    ///   - fallbackVersion: Version reported when no manifest is present
    ///     (the CLI's own version string).
    ///   - environment: Process environment, injectable for tests.
    public init(
        manifest: WorkspaceRemoteDaemonManifest?,
        homeDirectory: URL,
        fallbackVersion: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.manifest = manifest
        self.repository = RemoteDaemonManifestRepository(homeDirectory: homeDirectory)
        self.fallbackVersion = fallbackVersion
        if environment["CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1",
           let path = environment["CMUX_REMOTE_DAEMON_BINARY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            self.explicitBinaryURL = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
        } else {
            self.explicitBinaryURL = nil
        }
    }

    /// The version installed by this provider: the manifest's app version,
    /// or the fallback version for the dev override.
    public var version: String {
        manifest?.appVersion ?? fallbackVersion
    }

    /// See ``VPSDaemonArtifactProviding/expectedSHA256(goOS:goArch:)``.
    public func expectedSHA256(goOS: String, goArch: String) -> String? {
        if let explicitBinaryURL {
            return try? Self.sha256Hex(forFile: explicitBinaryURL)
        }
        return manifest?.entry(goOS: goOS, goArch: goArch)?.sha256.lowercased()
    }

    /// See ``VPSDaemonArtifactProviding/materialize(goOS:goArch:)``.
    public func materialize(goOS: String, goArch: String) async throws -> VPSDaemonArtifact {
        if let explicitBinaryURL {
            guard FileManager.default.isExecutableFile(atPath: explicitBinaryURL.path) else {
                throw VPSProvisioningError.artifactUnavailable(
                    detail: "CMUX_REMOTE_DAEMON_BINARY is not an executable file: \(explicitBinaryURL.path)"
                )
            }
            let sha = try Self.sha256Hex(forFile: explicitBinaryURL)
            return VPSDaemonArtifact(localURL: explicitBinaryURL, sha256: sha, version: version)
        }

        guard let manifest, let entry = manifest.entry(goOS: goOS, goArch: goArch) else {
            throw VPSProvisioningError.artifactUnavailable(
                detail: "this build has no verified cmuxd-remote manifest for \(goOS)-\(goArch); "
                    + "use a release or nightly build (see `cmux remote-daemon-status`)"
            )
        }

        let repository = self.repository
        let manifestVersion = manifest.appVersion
        let releaseURL = manifest.releaseURL
        do {
            // Bridges the legacy blocking repository (semaphore-waited
            // URLSession) off the cooperative pool; single sanctioned seam.
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        if let cached = try repository.validatedCachedBinary(entry: entry, version: manifestVersion) {
                            return cached
                        }
                        return try repository.downloadBinary(
                            entry: entry,
                            version: manifestVersion,
                            releaseURL: releaseURL
                        ).binaryURL
                    })
                }
            }
            let sha = try Self.sha256Hex(forFile: url)
            return VPSDaemonArtifact(localURL: url, sha256: sha, version: manifestVersion)
        } catch let error as VPSProvisioningError {
            throw error
        } catch {
            throw VPSProvisioningError.artifactUnavailable(detail: error.localizedDescription)
        }
    }

    private static func sha256Hex(forFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
