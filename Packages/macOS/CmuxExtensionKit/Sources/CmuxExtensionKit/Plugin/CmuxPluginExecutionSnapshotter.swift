import Darwin
import Foundation

/// Describes how a pinned plugin entrypoint must be started.
public enum CmuxPluginEntrypointExecution: Equatable, Sendable {
    /// The entrypoint is a native executable and can be started directly.
    case executable
    /// The entrypoint is a shebang script and must be passed to its interpreter.
    ///
    /// The arguments contain the interpreter path followed by any arguments from
    /// the shebang line. The pinned file descriptor is appended by the host.
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

    /// Creates an execution snapshot value.
    public init(
        directoryURL: URL,
        manifestURL: URL,
        entrypointURL: URL,
        fingerprint: String,
        entrypointFileDescriptor: Int32 = -1,
        entrypointExecution: CmuxPluginEntrypointExecution = .executable
    ) {
        self.directoryURL = directoryURL
        self.manifestURL = manifestURL
        self.entrypointURL = entrypointURL
        self.fingerprint = fingerprint
        self.entrypointFileDescriptor = entrypointFileDescriptor
        self.entrypointExecution = entrypointExecution
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
        let pinnedEntrypoint: (descriptor: Int32, execution: CmuxPluginEntrypointExecution)
        do {
            pinnedEntrypoint = try openEntrypoint(at: provisionalEntrypointURL)
            openEntrypointDescriptors.insert(pinnedEntrypoint.descriptor)
        } catch let error as CmuxPluginExecutionSnapshotError {
            removeStagingRoot(stagingRoot)
            throw error
        } catch {
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }

        let report = await CmuxPluginDirectoryLoader(directoryURL: stagingRoot).load()
        guard report.failures.isEmpty,
              let copiedPlugin = report.plugins.first(where: {
                  $0.manifest.id == plugin.manifest.id
              }) else {
            closeEntrypointDescriptor(pinnedEntrypoint.descriptor)
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.validationFailed
        }
        guard copiedPlugin.manifestFingerprint == plugin.manifestFingerprint else {
            closeEntrypointDescriptor(pinnedEntrypoint.descriptor)
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.fingerprintMismatch
        }
        guard let entrypointURL = copiedPlugin.entrypointURL else {
            closeEntrypointDescriptor(pinnedEntrypoint.descriptor)
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.missingEntrypoint
        }

        guard entrypointURL.standardizedFileURL == provisionalEntrypointURL else {
            closeEntrypointDescriptor(pinnedEntrypoint.descriptor)
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.missingEntrypoint
        }

        guard Darwin.fchflags(pinnedEntrypoint.descriptor, UInt32(UF_IMMUTABLE)) == 0 else {
            closeEntrypointDescriptor(pinnedEntrypoint.descriptor)
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }

        // Seal the descriptor before the final artifact read. A write that
        // raced the first validation is therefore either observed here and
        // rejected, or prevented from changing the bytes used at launch.
        let finalReport = await CmuxPluginDirectoryLoader(directoryURL: stagingRoot).load()
        guard finalReport.failures.isEmpty,
              let finalPlugin = finalReport.plugins.first(where: {
                  $0.manifest.id == plugin.manifest.id
              }),
              finalPlugin.manifestFingerprint == plugin.manifestFingerprint else {
            closeEntrypointDescriptor(pinnedEntrypoint.descriptor)
            removeStagingRoot(stagingRoot)
            throw CmuxPluginExecutionSnapshotError.fingerprintMismatch
        }

        return CmuxPluginExecutionSnapshot(
            directoryURL: copiedPlugin.directoryURL,
            manifestURL: copiedPlugin.directoryURL
                .appendingPathComponent("manifest.json", isDirectory: false),
            entrypointURL: entrypointURL,
            fingerprint: copiedPlugin.manifestFingerprint,
            entrypointFileDescriptor: pinnedEntrypoint.descriptor,
            entrypointExecution: pinnedEntrypoint.execution
        )
    }

    /// Removes a previously-created snapshot.
    public func remove(_ snapshot: CmuxPluginExecutionSnapshot) {
        closeEntrypointDescriptor(snapshot.entrypointFileDescriptor)
        removeStagingRoot(snapshot.directoryURL.deletingLastPathComponent())
    }

    private func openEntrypoint(
        at url: URL
    ) throws -> (descriptor: Int32, execution: CmuxPluginEntrypointExecution) {
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
                Darwin.close(executableDescriptor)
                return (readableDescriptor, .interpreter(interpreterArguments))
            }
            Darwin.close(readableDescriptor)
            return (executableDescriptor, .executable)
        } catch {
            Darwin.close(executableDescriptor)
            Darwin.close(readableDescriptor)
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

        let marker = Data("#!".utf8)
        guard prefix.starts(with: marker) else { return nil }
        guard let newline = prefix.firstIndex(of: 0x0A) else {
            throw CmuxPluginExecutionSnapshotError.invalidInterpreter
        }
        let line = String(decoding: prefix[marker.count..<newline], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let interpreter = arguments.first,
              interpreter.hasPrefix("/"),
              arguments.count <= 16,
              arguments.allSatisfy({ !$0.isEmpty && $0.count <= 256 }),
              arguments.allSatisfy({ !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              fileManager.isExecutableFile(atPath: interpreter) else {
            throw CmuxPluginExecutionSnapshotError.invalidInterpreter
        }
        return arguments
    }

    private func closeEntrypointDescriptor(_ descriptor: Int32) {
        guard descriptor >= 0, openEntrypointDescriptors.remove(descriptor) != nil else { return }
        _ = Darwin.fchflags(descriptor, UInt32(0))
        Darwin.close(descriptor)
    }

    private func removeStagingRoot(_ stagingRoot: URL) {
        let root = rootDirectoryURL.standardizedFileURL
        let candidate = stagingRoot.standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return }
        try? fileManager.removeItem(at: candidate)
    }
}
