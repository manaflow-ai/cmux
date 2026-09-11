import Darwin
import Foundation

/// Describes how a pinned plugin entrypoint must be started.
public enum CmuxPluginEntrypointExecution: Equatable, Sendable {
    /// The entrypoint is a native executable and can be started directly.
    case executable
    /// The entrypoint is a shebang script and must be passed to its interpreter.
    ///
    /// The arguments contain the shebang options after the interpreter path.
    /// The pinned interpreter and script descriptors are supplied separately.
    case interpreter([String])
}

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
    /// An open descriptor for the validated entrypoint bytes.
    ///
    /// The snapshotter owns this descriptor and closes it when ``remove(_:)``
    /// is called. Consumers must not close it directly; the descriptor is used
    /// to verify the launch path and to expose a stable script input stream.
    public let entrypointFileDescriptor: Int32
    /// How the copied entrypoint is launched, directly or through a shebang
    /// interpreter.
    public let entrypointExecution: CmuxPluginEntrypointExecution
    /// An open descriptor for the pinned shebang interpreter, when needed.
    /// The snapshotter owns and closes it with the snapshot; its bytes are
    /// compared with the resolved source interpreter before launch.
    public let interpreterFileDescriptor: Int32?
    /// The resolved source interpreter path used by Darwin's path-based
    /// launch API. Its bytes are checked against the pinned descriptor before
    /// the launch gate is released.
    public let interpreterURL: URL?
    /// Open descriptors for every regular file in the copied plugin bundle,
    /// keyed by path relative to ``directoryURL``. The verifier uses these
    /// identities to reject sibling replacement before capabilities are released.
    public let pinnedFileDescriptors: [String: Int32]

    /// Creates an execution snapshot value.
    ///
    /// - Parameter interpreterURL: The resolved source interpreter path when
    ///   the entrypoint is a shebang script.
    public init(
        directoryURL: URL,
        manifestURL: URL,
        entrypointURL: URL,
        fingerprint: String,
        entrypointFileDescriptor: Int32 = -1,
        entrypointExecution: CmuxPluginEntrypointExecution = .executable,
        interpreterFileDescriptor: Int32? = nil,
        pinnedFileDescriptors: [String: Int32] = [:],
        interpreterURL: URL? = nil
    ) {
        self.directoryURL = directoryURL
        self.manifestURL = manifestURL
        self.entrypointURL = entrypointURL
        self.fingerprint = fingerprint
        self.entrypointFileDescriptor = entrypointFileDescriptor
        self.entrypointExecution = entrypointExecution
        self.interpreterFileDescriptor = interpreterFileDescriptor
        self.pinnedFileDescriptors = pinnedFileDescriptors
        self.interpreterURL = interpreterURL
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
    /// The validated entrypoint could not be pinned for launch.
    case entrypointDescriptorFailed
    /// A shebang was present but did not name a safe executable interpreter.
    case invalidInterpreter
}

/// Copies approved plugin bundles before launch to close path-based TOCTOU gaps.
///
/// The loader fingerprints every regular file in the copied bundle. A source
/// mutation during copying therefore fails closed, while later source changes
/// cannot affect the already-created process working directory.
public actor CmuxPluginExecutionSnapshotter {
    let rootDirectoryURL: URL
    let fileManager: FileManager
    let artifactCopier: CmuxPluginBoundedArtifactCopier
    var openEntrypointDescriptors: Set<Int32> = []
    var activeSnapshotStagingRoots: Set<URL> = []
    static let orphanSnapshotAge: TimeInterval = 24 * 60 * 60
    static let maximumOrphanSnapshotCount = 2

    /// Creates a snapshotter with an injected private staging root.
    public init(
        rootDirectoryURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-plugin-snapshots-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            ),
        fileManager: FileManager = .default
    ) {
        self.rootDirectoryURL = rootDirectoryURL.standardizedFileURL
        self.fileManager = fileManager
        self.artifactCopier = CmuxPluginBoundedArtifactCopier(fileManager: fileManager)
        Task { [weak self] in
            await self?.pruneOrphanedSnapshots()
        }
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
        var snapshotCommitted = false
        var preparedInterpreterDescriptor: Int32?
        var pinnedFileDescriptors: [String: Int32] = [:]
        defer {
            if !snapshotCommitted, let preparedInterpreterDescriptor {
                closeEntrypointDescriptor(preparedInterpreterDescriptor)
            }
            if !snapshotCommitted {
                for descriptor in pinnedFileDescriptors.values {
                    closeEntrypointDescriptor(descriptor)
                }
            }
            if !snapshotCommitted {
                removeStagingRoot(stagingRoot)
            }
        }

        do {
            try fileManager.createDirectory(
                at: stagingRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try artifactCopier.copyDirectory(
                from: sourceDirectory,
                to: copiedDirectory
            )
        } catch {
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.copyFailed
        }

        // Pruning runs in an unstructured initialization task and can execute
        // while the loader below is suspended. Mark this staging root active
        // before that suspension so it cannot be mistaken for an orphan.
        let activeStagingRoot = canonicalURL(stagingRoot)
        activeSnapshotStagingRoots.insert(activeStagingRoot)
        defer { activeSnapshotStagingRoots.remove(activeStagingRoot) }

        guard let declaredEntrypoint = plugin.manifest.entrypoint else {
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.missingEntrypoint
        }
        let provisionalEntrypointURL = copiedDirectory
            .appendingPathComponent(declaredEntrypoint, isDirectory: false)
            .standardizedFileURL
        guard provisionalEntrypointURL.path.hasPrefix(copiedDirectory.path + "/") else {
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.missingEntrypoint
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

        guard canonicalURL(entrypointURL) == canonicalURL(provisionalEntrypointURL) else {
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.missingEntrypoint
        }

        let preparedInterpreter = try CmuxPluginInterpreterSnapshotter(
            fileManager: fileManager
        ).makeSnapshot(
            for: provisionalEntrypointURL,
            stagingRoot: stagingRoot
        )
        preparedInterpreterDescriptor = preparedInterpreter?.descriptor
        if let descriptor = preparedInterpreter?.descriptor {
            openEntrypointDescriptors.insert(descriptor)
        }
        let copiedManifestURL = copiedDirectory
            .appendingPathComponent("manifest.json", isDirectory: false)
        guard let copiedManifestData = readBoundedFile(
            at: copiedManifestURL,
            maximumBytes: CmuxPluginDirectoryLoader.maximumManifestBytes
        ) else {
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.validationFailed
        }
        let copiedFingerprint = try CmuxPluginArtifactFingerprinter().fingerprint(
            manifestData: copiedManifestData,
            pluginDirectoryURL: copiedDirectory,
            entrypointDeclaration: declaredEntrypoint,
            interpreterData: preparedInterpreter?.data
        )
        guard copiedFingerprint == plugin.manifestFingerprint else {
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.fingerprintMismatch
        }

        do {
            try sealSnapshot(at: stagingRoot)
        } catch let error as CmuxPluginExecutionSnapshotError {
            removeStagingRoot(stagingRoot)
            throw error
        } catch {
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }

        do {
            pinnedFileDescriptors = try openPinnedFiles(at: copiedDirectory)
            pinnedFileDescriptors.values.forEach { openEntrypointDescriptors.insert($0) }
        } catch let error as CmuxPluginExecutionSnapshotError {
            removeStagingRoot(stagingRoot)
            throw error
        } catch {
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }

        // Open only after the complete staging tree is immutable. A malicious
        // same-user process can race the first pathname scan, but it cannot
        // substitute the inode selected here after the root directory is sealed.
        let pinnedEntrypoint: (
            descriptor: Int32,
            execution: CmuxPluginEntrypointExecution,
            interpreterDescriptor: Int32?,
            interpreterURL: URL?
        )
        do {
            pinnedEntrypoint = try openEntrypoint(
                at: provisionalEntrypointURL,
                interpreterDescriptor: preparedInterpreter?.descriptor,
                interpreterURL: preparedInterpreter?.sourceURL
            )
            openEntrypointDescriptors.insert(pinnedEntrypoint.descriptor)
        } catch let error as CmuxPluginExecutionSnapshotError {
            removeStagingRoot(stagingRoot)
            throw error
        } catch {
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }

        guard Darwin.fchflags(pinnedEntrypoint.descriptor, UInt32(UF_IMMUTABLE)) == 0 else {
            closeEntrypointDescriptor(pinnedEntrypoint.descriptor)
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }

        snapshotCommitted = true
        return CmuxPluginExecutionSnapshot(
            directoryURL: copiedPlugin.directoryURL,
            manifestURL: copiedPlugin.directoryURL
                .appendingPathComponent("manifest.json", isDirectory: false),
            entrypointURL: entrypointURL,
            fingerprint: copiedPlugin.manifestFingerprint,
            entrypointFileDescriptor: pinnedEntrypoint.descriptor,
            entrypointExecution: pinnedEntrypoint.execution,
            interpreterFileDescriptor: pinnedEntrypoint.interpreterDescriptor,
            pinnedFileDescriptors: pinnedFileDescriptors,
            interpreterURL: pinnedEntrypoint.interpreterURL
        )
    }

    /// Removes a previously-created snapshot.
    public func remove(_ snapshot: CmuxPluginExecutionSnapshot) {
        closeEntrypointDescriptor(snapshot.entrypointFileDescriptor)
        closeEntrypointDescriptor(snapshot.interpreterFileDescriptor ?? -1)
        for descriptor in snapshot.pinnedFileDescriptors.values {
            closeEntrypointDescriptor(descriptor)
        }
        removeStagingRoot(snapshot.directoryURL.deletingLastPathComponent())
    }

    /// Revalidates a snapshot before its launch gate grants plugin capabilities.
    public func verify(_ snapshot: CmuxPluginExecutionSnapshot) -> Bool {
        CmuxPluginExecutionSnapshotVerifier(fileManager: fileManager).verify(snapshot)
    }

}
