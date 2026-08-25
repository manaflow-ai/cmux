import Darwin
import Foundation

/// Copies and pins the external interpreter named by a plugin shebang.
///
/// The returned descriptor belongs to the caller. The source interpreter is
/// never modified; only the private copy receives the immutable flag.
struct CmuxPluginInterpreterSnapshotter {
    private static let maximumInterpreterBytes: UInt64 = 512 * 1024 * 1024
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Creates a sealed private interpreter copy when the entrypoint is a script.
    func makeSnapshot(
        for entrypointURL: URL,
        stagingRoot: URL
    ) throws -> (descriptor: Int32, data: Data)? {
        let entrypointDescriptor = Darwin.open(
            entrypointURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard entrypointDescriptor >= 0 else {
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }
        defer { Darwin.close(entrypointDescriptor) }

        let prefix = try readPrefix(from: entrypointDescriptor)
        let shebang: CmuxPluginShebang?
        do {
            shebang = try CmuxPluginShebang.parse(prefix: prefix)
        } catch {
            throw CmuxPluginExecutionSnapshotError.invalidInterpreter
        }
        guard let shebang else { return nil }
        guard fileManager.isExecutableFile(atPath: shebang.interpreterPath) else {
            throw CmuxPluginExecutionSnapshotError.invalidInterpreter
        }

        let resolvedInterpreterURL = URL(fileURLWithPath: shebang.interpreterPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let sourceDescriptor = Darwin.open(
            resolvedInterpreterURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDescriptor >= 0 else {
            throw CmuxPluginExecutionSnapshotError.invalidInterpreter
        }
        defer { Darwin.close(sourceDescriptor) }
        guard let sourceSize = regularFileSize(sourceDescriptor),
              sourceSize <= Self.maximumInterpreterBytes else {
            throw CmuxPluginExecutionSnapshotError.invalidInterpreter
        }
        let data = try readAll(from: sourceDescriptor)

        let interpreterDirectory = stagingRoot
            .appendingPathComponent(".cmux-interpreter", isDirectory: true)
        try fileManager.createDirectory(
            at: interpreterDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let copiedURL = interpreterDirectory
            .appendingPathComponent("executable", isDirectory: false)
        let copiedDescriptor = Darwin.open(
            copiedURL.path,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o755
        )
        guard copiedDescriptor >= 0 else {
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }
        defer { Darwin.close(copiedDescriptor) }
        try writeAll(data, to: copiedDescriptor)
        guard Darwin.lseek(copiedDescriptor, 0, SEEK_SET) >= 0,
              try readAll(from: copiedDescriptor) == data else {
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }

        // Seal the inode through the descriptor created with O_EXCL before
        // resolving the pathname for the launch descriptor.
        guard Darwin.fchflags(copiedDescriptor, UInt32(UF_IMMUTABLE)) == 0 else {
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }
        let executableDescriptor = Darwin.open(
            copiedURL.path,
            O_EXEC | O_NOFOLLOW
        )
        guard executableDescriptor >= 0 else {
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }
        guard sameFile(copiedDescriptor, executableDescriptor) else {
            Darwin.close(executableDescriptor)
            throw CmuxPluginExecutionSnapshotError.fingerprintMismatch
        }
        return (executableDescriptor, data)
    }

    private func readPrefix(from descriptor: Int32) throws -> Data {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            return try handle.read(upToCount: 4096) ?? Data()
        } catch {
            throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
        }
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
            if UInt64(data.count) > Self.maximumInterpreterBytes {
                throw CmuxPluginExecutionSnapshotError.invalidInterpreter
            }
        }
        return data
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                guard written > 0 else {
                    throw CmuxPluginExecutionSnapshotError.entrypointDescriptorFailed
                }
                offset += written
            }
        }
    }

    private func regularFileSize(_ descriptor: Int32) -> UInt64? {
        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_size >= 0 else {
            return nil
        }
        return UInt64(metadata.st_size)
    }

    private func sameFile(_ left: Int32, _ right: Int32) -> Bool {
        var leftMetadata = Darwin.stat()
        var rightMetadata = Darwin.stat()
        guard Darwin.fstat(left, &leftMetadata) == 0,
              Darwin.fstat(right, &rightMetadata) == 0 else {
            return false
        }
        return leftMetadata.st_dev == rightMetadata.st_dev
            && leftMetadata.st_ino == rightMetadata.st_ino
    }
}
