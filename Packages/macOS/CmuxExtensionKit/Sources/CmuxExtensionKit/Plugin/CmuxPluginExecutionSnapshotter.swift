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
    /// is called. Consumers must not close it directly; the descriptor exists
    /// to make launch independent of later pathname replacement.
    public let entrypointFileDescriptor: Int32
    /// Whether the descriptor is launched directly or through a shebang
    /// interpreter.
    public let entrypointExecution: CmuxPluginEntrypointExecution
    /// An open descriptor for the pinned shebang interpreter, when needed.
    /// The snapshotter owns and closes it with the snapshot.
    public let interpreterFileDescriptor: Int32?
    /// Open descriptors for every regular file in the copied plugin bundle,
    /// keyed by path relative to ``directoryURL``. The verifier uses these
    /// identities to reject sibling replacement before capabilities are released.
    public let pinnedFileDescriptors: [String: Int32]

    /// Creates an execution snapshot value.
    public init(
        directoryURL: URL,
        manifestURL: URL,
        entrypointURL: URL,
        fingerprint: String,
        entrypointFileDescriptor: Int32 = -1,
        entrypointExecution: CmuxPluginEntrypointExecution = .executable,
        interpreterFileDescriptor: Int32? = nil,
        pinnedFileDescriptors: [String: Int32] = [:]
    ) {
        self.directoryURL = directoryURL
        self.manifestURL = manifestURL
        self.entrypointURL = entrypointURL
        self.fingerprint = fingerprint
        self.entrypointFileDescriptor = entrypointFileDescriptor
        self.entrypointExecution = entrypointExecution
        self.interpreterFileDescriptor = interpreterFileDescriptor
        self.pinnedFileDescriptors = pinnedFileDescriptors
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
    private let rootDirectoryURL: URL
    private let fileManager: FileManager
    private var openEntrypointDescriptors: Set<Int32> = []
    private static let orphanSnapshotAge: TimeInterval = 24 * 60 * 60
    private static let maximumOrphanSnapshotCount = 2

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
            try fileManager.copyItem(at: sourceDirectory, to: copiedDirectory)
        } catch {
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.copyFailed
        }

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

        guard entrypointURL.standardizedFileURL == provisionalEntrypointURL else {
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
            interpreterDescriptor: Int32?
        )
        do {
            pinnedEntrypoint = try openEntrypoint(
                at: provisionalEntrypointURL,
                interpreterDescriptor: preparedInterpreter?.descriptor
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
            pinnedFileDescriptors: pinnedFileDescriptors
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

    private func openEntrypoint(
        at url: URL,
        interpreterDescriptor: Int32?
    ) throws -> (
        descriptor: Int32,
        execution: CmuxPluginEntrypointExecution,
        interpreterDescriptor: Int32?
    ) {
        let executableDescriptor = Darwin.open(url.path, O_EXEC)
        guard executableDescriptor >= 0 else {
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }

        let readableDescriptor = Darwin.open(url.path, O_RDONLY)
        guard readableDescriptor >= 0 else {
            Darwin.close(executableDescriptor)
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }

        do {
            if let interpreterArguments = try shebangArguments(from: readableDescriptor) {
                guard interpreterDescriptor != nil else {
                    throw CmuxPluginExecutionSnapshotError.invalidInterpreter
                }
                Darwin.close(executableDescriptor)
                return (
                    readableDescriptor,
                    .interpreter(Array(interpreterArguments.dropFirst())),
                    interpreterDescriptor
                )
            }
            guard interpreterDescriptor == nil else {
                throw CmuxPluginExecutionSnapshotError.invalidInterpreter
            }
            Darwin.close(readableDescriptor)
            return (executableDescriptor, .executable, nil)
        } catch {
            Darwin.close(executableDescriptor)
            Darwin.close(readableDescriptor)
            throw error
        }
    }

    private func openPinnedFiles(at root: URL) throws -> [String: Int32] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw CmuxPluginExecutionSnapshotError.validationFailed
        }
        var descriptors: [String: Int32] = [:]
        var entryCount = 0
        do {
            for case let url as URL in enumerator {
                guard entryCount < CmuxPluginArtifactFingerprinter.maximumArtifactEntries else {
                    throw CmuxPluginExecutionSnapshotError.validationFailed
                }
                entryCount += 1
                let values = try url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isSymbolicLink != true else {
                    throw CmuxPluginExecutionSnapshotError.validationFailed
                }
                guard values.isDirectory != true else { continue }
                guard values.isRegularFile == true,
                      url.path.hasPrefix(root.path + "/") else {
                    throw CmuxPluginExecutionSnapshotError.validationFailed
                }
                guard descriptors.count < CmuxPluginArtifactFingerprinter.maximumArtifactFiles else {
                    throw CmuxPluginExecutionSnapshotError.validationFailed
                }
                let descriptor = Darwin.open(
                    url.path,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else {
                    throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
                }
                let relativePath = String(url.path.dropFirst(root.path.count + 1))
                descriptors[relativePath] = descriptor
            }
            return descriptors
        } catch {
            descriptors.values.forEach { Darwin.close($0) }
            throw error
        }
    }

    private func shebangArguments(from descriptor: Int32) throws -> [String]? {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let prefix: Data
        do {
            prefix = try handle.read(upToCount: 4096) ?? Data()
            try handle.seek(toOffset: 0)
        } catch {
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }

        let shebang: CmuxPluginShebang?
        do {
            shebang = try CmuxPluginShebang.parse(prefix: prefix)
        } catch {
            throw CmuxPluginExecutionSnapshotError.invalidInterpreter
        }
        guard let shebang else { return nil }
        return [shebang.interpreterPath] + shebang.arguments
    }

    private func closeEntrypointDescriptor(_ descriptor: Int32, clearImmutable: Bool = true) {
        guard descriptor >= 0, openEntrypointDescriptors.remove(descriptor) != nil else { return }
        if clearImmutable {
            _ = Darwin.fchflags(descriptor, UInt32(0))
        }
        Darwin.close(descriptor)
    }

    private func sealSnapshot(at stagingRoot: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: stagingRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw CmuxPluginExecutionSnapshotError.validationFailed
        }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw CmuxPluginExecutionSnapshotError.validationFailed
            }
            if values.isDirectory == true {
                directories.append(url)
            } else if values.isRegularFile == true {
                try sealFile(at: url)
            } else {
                throw CmuxPluginExecutionSnapshotError.validationFailed
            }
        }

        // Seal children before parents so cleanup can reverse the operation
        // without attempting to mutate an immutable directory.
        for directory in directories.sorted(by: { depth(of: $0) > depth(of: $1) }) {
            try sealFile(at: directory, isDirectory: true)
        }
        try sealFile(at: stagingRoot, isDirectory: true)
    }

    private func sealFile(at url: URL, isDirectory: Bool = false) throws {
        let flags = O_RDONLY | O_NOFOLLOW | (isDirectory ? O_DIRECTORY : 0)
        let descriptor = Darwin.open(url.path, flags)
        guard descriptor >= 0 else {
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchflags(descriptor, UInt32(UF_IMMUTABLE)) == 0 else {
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }
    }

    private func clearImmutableFlags(at root: URL) {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: []
              ) else { return }
        var directories: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                continue
            }
            if values?.isDirectory == true {
                directories.append(url)
                continue
            }
            clearImmutableFlag(at: url)
        }
        for directory in directories.sorted(by: { depth(of: $0) > depth(of: $1) }) {
            clearImmutableFlag(at: directory, isDirectory: true)
        }
        clearImmutableFlag(at: root, isDirectory: true)
    }

    private func clearImmutableFlag(at url: URL, isDirectory: Bool = false) {
        let flags = O_RDONLY | O_NOFOLLOW | (isDirectory ? O_DIRECTORY : 0)
        let descriptor = Darwin.open(url.path, flags)
        guard descriptor >= 0 else { return }
        _ = Darwin.fchflags(descriptor, UInt32(0))
        Darwin.close(descriptor)
    }

    private func depth(of url: URL) -> Int {
        url.standardizedFileURL.pathComponents.count
    }

    private func removeStagingRoot(
        _ stagingRoot: URL,
        within rootDirectory: URL? = nil
    ) {
        let root = (rootDirectory ?? rootDirectoryURL).standardizedFileURL
        let candidate = stagingRoot.standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return }
        guard let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            try? fileManager.removeItem(at: candidate)
            return
        }
        clearImmutableFlags(at: candidate)
        try? fileManager.removeItem(at: candidate)
    }

    /// Recovers UUID-named snapshots left by a crashed or force-quit host.
    /// The default root is process-scoped, and only roots older than a day are
    /// removed. Across dead process roots, at most two recent snapshots survive;
    /// with the 256 MiB bundle/interpreter caps this also bounds retained bytes.
    private func pruneOrphanedSnapshots() {
        let cutoff = Date().addingTimeInterval(-Self.orphanSnapshotAge)
        let rootName = rootDirectoryURL.lastPathComponent
        let roots: [URL]
        if rootName.hasPrefix("cmux-plugin-snapshots-") {
            let parent = rootDirectoryURL.deletingLastPathComponent()
            roots = (try? fileManager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ))?.filter { $0.lastPathComponent.hasPrefix("cmux-plugin-snapshots-") }
                ?? [rootDirectoryURL]
        } else {
            roots = [rootDirectoryURL]
        }

        var orphaned: [(url: URL, root: URL, modified: Date)] = []
        for root in roots {
            guard let rootValues = try? root.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ),
                  rootValues.isDirectory == true,
                  rootValues.isSymbolicLink != true else {
                continue
            }
            if root.standardizedFileURL != rootDirectoryURL.standardizedFileURL,
               let pid = snapshotRootProcessID(root.lastPathComponent),
               isProcessAlive(pid) {
                continue
            }
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                guard UUID(uuidString: entry.lastPathComponent) != nil,
                      let values = try? entry.resourceValues(
                          forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                      ),
                      values.isDirectory == true,
                      values.isSymbolicLink != true,
                      let attributes = try? fileManager.attributesOfItem(atPath: entry.path),
                      let modified = attributes[.modificationDate] as? Date else {
                    continue
                }
                orphaned.append((entry, root, modified))
            }
        }
        for (index, candidate) in orphaned
            .sorted(by: { $0.modified > $1.modified })
            .enumerated()
        where index >= Self.maximumOrphanSnapshotCount || candidate.modified < cutoff {
            removeStagingRoot(candidate.url, within: candidate.root)
        }
    }

    private func snapshotRootProcessID(_ name: String) -> pid_t? {
        guard let raw = name.split(separator: "-").last,
              let value = Int32(raw),
              value > 1 else { return nil }
        return value
    }

    private func isProcessAlive(_ processID: pid_t) -> Bool {
        Darwin.kill(processID, 0) == 0 || errno == EPERM
    }

    private func readBoundedFile(at url: URL, maximumBytes: Int) -> Data? {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(maximumBytes) else {
            return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        do {
            while data.count <= maximumBytes {
                let remaining = maximumBytes + 1 - data.count
                let chunk = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
        } catch {
            return nil
        }
        return data.count <= maximumBytes ? data : nil
    }
}
