import CryptoKit
import Foundation

/// A validated plugin discovered in a plugin directory.
public struct CmuxLoadedPlugin: Equatable, Sendable {
    /// The decoded, validated manifest.
    public let manifest: CmuxExtensionManifest
    /// The directory containing `manifest.json`.
    public let directoryURL: URL
    /// The validated executable URL, when the manifest declares one.
    public let entrypointURL: URL?
    /// Stable fingerprint used to invalidate stale permission grants.
    public let manifestFingerprint: String

    /// Creates a loaded plugin value.
    public init(
        manifest: CmuxExtensionManifest,
        directoryURL: URL,
        entrypointURL: URL?,
        manifestFingerprint: String
    ) {
        self.manifest = manifest
        self.directoryURL = directoryURL
        self.entrypointURL = entrypointURL
        self.manifestFingerprint = manifestFingerprint
    }
}

/// A load failure retained for Settings and diagnostics instead of silently
/// dropping a broken plugin directory.
public struct CmuxPluginLoadFailure: Equatable, Sendable {
    /// Directory whose manifest failed to load.
    public let directoryURL: URL
    /// A stable, machine-readable failure category.
    public let code: Code
    /// Human-readable detail suitable for a diagnostics/settings row.
    public let detail: String

    /// Failure categories emitted by ``CmuxPluginDirectoryLoader``.
    public enum Code: String, Codable, Equatable, Sendable {
        /// The configured plugin root exists but cannot be enumerated.
        case unreadableDirectory
        /// A child plugin directory does not contain `manifest.json`.
        case missingManifest
        /// The manifest cannot be read safely or exceeds the size limit.
        case unreadableManifest
        /// The manifest bytes are not valid for ``CmuxExtensionManifest``.
        case malformedManifest
        /// The decoded manifest violates the plugin contract.
        case invalidManifest
        /// The manifest identifier differs from its containing directory.
        case directoryIdentifierMismatch
        /// The declared executable is absent, non-regular, or non-executable.
        case missingEntrypoint
        /// More than one discovered plugin declares the same identifier.
        case duplicateIdentifier
    }

    /// Creates a load failure.
    public init(directoryURL: URL, code: Code, detail: String) {
        self.directoryURL = directoryURL
        self.code = code
        self.detail = detail
    }
}

/// Result of one deterministic plugin-directory scan.
public struct CmuxPluginLoadReport: Equatable, Sendable {
    /// Valid plugins, sorted by manifest id.
    public let plugins: [CmuxLoadedPlugin]
    /// Failures, sorted by directory path.
    public let failures: [CmuxPluginLoadFailure]

    /// Creates a load report.
    public init(plugins: [CmuxLoadedPlugin], failures: [CmuxPluginLoadFailure]) {
        self.plugins = plugins
        self.failures = failures
    }
}

/// Scans a user plugin directory and validates every child manifest.
///
/// The loader is an actor because a host commonly rescans in response to a
/// file-system signal while Settings and command-palette reads happen on the
/// main actor. It performs no launch or permission side effects; those are
/// owned by the host runtime after it receives this report.
public actor CmuxPluginDirectoryLoader {
    /// Maximum manifest size accepted from disk.
    public static let maximumManifestBytes = 256 * 1024

    /// Default user plugin directory (`~/Library/Application Support/cmux/plugins`).
    public static var defaultDirectoryURL: URL {
        defaultDirectoryURL(fileManager: .default)
    }

    private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("cmux", isDirectory: true)
                .appendingPathComponent("plugins", isDirectory: true)
    }

    /// Directory scanned by this loader.
    public let directoryURL: URL
    /// API version used for plugin compatibility checks.
    public let supportedAPIVersion: CmuxExtensionAPIVersion
    private let fileManager: FileManager

    /// Creates a loader for `directoryURL`.
    public init(
        directoryURL: URL = CmuxPluginDirectoryLoader.defaultDirectoryURL,
        supportedAPIVersion: CmuxExtensionAPIVersion = .pluginV3,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.supportedAPIVersion = supportedAPIVersion
        self.fileManager = fileManager
    }

    /// Scans the directory and returns both valid plugins and load failures.
    public func load() -> CmuxPluginLoadReport {
        let resolvedRoot = directoryURL.resolvingSymlinksInPath().standardizedFileURL
        // A missing plugin directory is the normal first-launch state and is
        // not presented as a load error. Any existing-but-unreadable root is
        // actionable and must remain visible in Settings.
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return CmuxPluginLoadReport(plugins: [], failures: [])
        }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return CmuxPluginLoadReport(
                plugins: [],
                failures: [CmuxPluginLoadFailure(
                    directoryURL: directoryURL,
                    code: .unreadableDirectory,
                    detail: error.localizedDescription
                )]
            )
        }

        var plugins: [CmuxLoadedPlugin] = []
        var failures: [CmuxPluginLoadFailure] = []
        var ids = Set<String>()

        for directory in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let resourceValues = try? directory.resourceValues(forKeys: [.isDirectoryKey]),
                  resourceValues.isDirectory == true else {
                continue
            }
            let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                failures.append(CmuxPluginLoadFailure(
                    directoryURL: directory,
                    code: .missingManifest,
                    detail: "manifest.json is missing"
                ))
                continue
            }
            let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedDirectory.path.hasPrefix(resolvedRoot.path + "/") else {
                failures.append(CmuxPluginLoadFailure(
                    directoryURL: directory,
                    code: .invalidManifest,
                    detail: "plugin directory resolves outside the configured plugin root"
                ))
                continue
            }
            let resolvedManifest = manifestURL.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedManifest.path.hasPrefix(resolvedDirectory.path + "/") else {
                failures.append(CmuxPluginLoadFailure(
                    directoryURL: directory,
                    code: .invalidManifest,
                    detail: "manifest.json resolves outside the plugin directory"
                ))
                continue
            }
            guard let manifestValues = try? resolvedManifest.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ),
                  manifestValues.isRegularFile == true,
                  (manifestValues.fileSize ?? Self.maximumManifestBytes + 1) <= Self.maximumManifestBytes,
                  let data = try? Data(contentsOf: resolvedManifest),
                  data.count <= Self.maximumManifestBytes else {
                failures.append(CmuxPluginLoadFailure(
                    directoryURL: directory,
                    code: .unreadableManifest,
                    detail: "manifest.json is unreadable or exceeds \(Self.maximumManifestBytes) bytes"
                ))
                continue
            }

            let manifest: CmuxExtensionManifest
            do {
                manifest = try JSONDecoder().decode(CmuxExtensionManifest.self, from: data)
            } catch {
                failures.append(CmuxPluginLoadFailure(
                    directoryURL: directory,
                    code: .malformedManifest,
                    detail: String(describing: error)
                ))
                continue
            }

            do {
                try validatePluginManifest(manifest, supportedAPIVersion: supportedAPIVersion)
            } catch let error as CmuxExtensionValidationError {
                failures.append(CmuxPluginLoadFailure(
                    directoryURL: directory,
                    code: Self.failureCode(for: error),
                    detail: String(describing: error)
                ))
                continue
            } catch {
                failures.append(CmuxPluginLoadFailure(
                    directoryURL: directory,
                    code: .invalidManifest,
                    detail: String(describing: error)
                ))
                continue
            }

            let directoryID = directory.lastPathComponent
            guard manifest.id == directoryID else {
                failures.append(CmuxPluginLoadFailure(
                    directoryURL: directory,
                    code: .directoryIdentifierMismatch,
                    detail: "manifest id \(manifest.id) does not match directory \(directoryID)"
                ))
                continue
            }
            guard ids.insert(manifest.id).inserted else {
                failures.append(CmuxPluginLoadFailure(
                    directoryURL: directory,
                    code: .duplicateIdentifier,
                    detail: "plugin id \(manifest.id) was already loaded"
                ))
                continue
            }

            let entrypointURL: URL?
            if let entrypoint = manifest.entrypoint {
                // Resolve symlinks before containment checks. A relative path
                // that looks safe lexically must not escape through a symlink
                // planted inside the plugin directory.
                let root = resolvedDirectory
                let candidate = directory
                    .appendingPathComponent(entrypoint)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                let resourceValues = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
                guard candidate.path.hasPrefix(root.path + "/"),
                      resourceValues?.isRegularFile == true,
                      fileManager.isExecutableFile(atPath: candidate.path) else {
                    failures.append(CmuxPluginLoadFailure(
                        directoryURL: directory,
                        code: .missingEntrypoint,
                        detail: "entrypoint \(entrypoint) is missing or not executable"
                    ))
                    continue
                }
                entrypointURL = candidate
            } else {
                entrypointURL = nil
            }

            plugins.append(CmuxLoadedPlugin(
                manifest: manifest,
                directoryURL: directory,
                entrypointURL: entrypointURL,
                manifestFingerprint: Self.fingerprint(data)
            ))
        }

        return CmuxPluginLoadReport(
            plugins: plugins.sorted { $0.manifest.id < $1.manifest.id },
            failures: failures.sorted { $0.directoryURL.path < $1.directoryURL.path }
        )
    }

    private static let lowercaseHexDigits = Array("0123456789abcdef".utf8)

    private static func fingerprint(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digest.count * 2)
        for byte in digest {
            bytes.append(lowercaseHexDigits[Int(byte >> 4)])
            bytes.append(lowercaseHexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func failureCode(for error: CmuxExtensionValidationError) -> CmuxPluginLoadFailure.Code {
        switch error {
        case .invalidEntrypoint:
            return .missingEntrypoint
        case .directoryIdentifierMismatch:
            return .directoryIdentifierMismatch
        case .duplicatePluginIdentifier:
            return .duplicateIdentifier
        case .malformedManifest:
            return .malformedManifest
        case .missingEntrypointDeclaration:
            return .missingEntrypoint
        default:
            return .invalidManifest
        }
    }
}
