import Foundation

/// A private copy of a validated plugin used for one supervised process.
public struct CmuxPluginExecutionSnapshot: Equatable, Sendable {
    /// The copied plugin directory used as the process working directory.
    public let directoryURL: URL
    /// The copied manifest path exposed to the plugin process.
    public let manifestURL: URL
    /// The copied executable launched by the process supervisor.
    public let entrypointURL: URL
    /// The artifact fingerprint revalidated after copying.
    public let fingerprint: String

    /// Creates an execution snapshot value.
    public init(
        directoryURL: URL,
        manifestURL: URL,
        entrypointURL: URL,
        fingerprint: String
    ) {
        self.directoryURL = directoryURL
        self.manifestURL = manifestURL
        self.entrypointURL = entrypointURL
        self.fingerprint = fingerprint
    }
}

/// Errors raised while creating an isolated plugin execution snapshot.
public enum CmuxPluginExecutionSnapshotError: Error, Equatable, Sendable {
    /// The source bundle could not be copied into the private staging root.
    case copyFailed
    /// The copied bundle did not produce a valid plugin report.
    case validationFailed
    /// The copied bytes differ from the approved artifact fingerprint.
    case fingerprintMismatch
    /// The copied manifest did not resolve to an executable entrypoint.
    case missingEntrypoint
}

/// Copies approved plugin bundles before launch to close path-based TOCTOU gaps.
///
/// The loader fingerprints every regular file in the copied bundle. A source
/// mutation during copying therefore fails closed, while later source changes
/// cannot affect the already-created process working directory.
public actor CmuxPluginExecutionSnapshotter {
    private let rootDirectoryURL: URL
    private let fileManager: FileManager

    /// Creates a snapshotter with an injected private staging root.
    public init(
        rootDirectoryURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-plugin-snapshots", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.rootDirectoryURL = rootDirectoryURL.standardizedFileURL
        self.fileManager = fileManager
    }

    /// Copies and revalidates one approved plugin artifact.
    ///
    /// - Parameter plugin: The loader-validated plugin whose fingerprint must
    ///   match the copied bundle.
    /// - Returns: A private execution snapshot for the plugin process.
    /// - Throws: ``CmuxPluginExecutionSnapshotError`` when copying or
    ///   revalidation fails.
    public func makeSnapshot(
        for plugin: CmuxLoadedPlugin
    ) async throws -> CmuxPluginExecutionSnapshot {
        let sourceDirectory = plugin.directoryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let stagingRoot = rootDirectoryURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copiedDirectory = stagingRoot
            .appendingPathComponent(plugin.manifest.id, isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: stagingRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try fileManager.copyItem(at: sourceDirectory, to: copiedDirectory)
        } catch {
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.copyFailed
        }

        let report = await CmuxPluginDirectoryLoader(directoryURL: stagingRoot).load()
        guard report.failures.isEmpty,
              let copiedPlugin = report.plugins.first(where: {
                  $0.manifest.id == plugin.manifest.id
              }) else {
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.validationFailed
        }
        guard copiedPlugin.manifestFingerprint == plugin.manifestFingerprint else {
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.fingerprintMismatch
        }
        guard let entrypointURL = copiedPlugin.entrypointURL else {
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.missingEntrypoint
        }

        return CmuxPluginExecutionSnapshot(
            directoryURL: copiedPlugin.directoryURL,
            manifestURL: copiedPlugin.directoryURL
                .appendingPathComponent("manifest.json", isDirectory: false),
            entrypointURL: entrypointURL,
            fingerprint: copiedPlugin.manifestFingerprint
        )
    }

    /// Removes a previously-created snapshot.
    public func remove(_ snapshot: CmuxPluginExecutionSnapshot) {
        removeStagingRoot(snapshot.directoryURL.deletingLastPathComponent())
    }

    private func removeStagingRoot(_ stagingRoot: URL) {
        let root = rootDirectoryURL.standardizedFileURL
        let candidate = stagingRoot.standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return }
        try? fileManager.removeItem(at: candidate)
    }
}
