import Darwin
import Dispatch
import Foundation

extension GitMetadataService {
    private struct GitTrackedChangesResolution: Sendable {
        let snapshot: GitTrackedChangesSnapshot
        let degradationReason: GitMetadataDegradationReason?

        init(
            snapshot: GitTrackedChangesSnapshot,
            degradationReason: GitMetadataDegradationReason? = nil
        ) {
            self.snapshot = snapshot
            self.degradationReason = degradationReason
        }
    }

    private nonisolated static let gitIndexHexAlphabet = Array("0123456789abcdef".utf8)

    /// Compares the working tree against the parsed index to decide dirtiness.
    ///
    /// Mirrors git's stat-based dirty check: for each tracked entry it reads the
    /// file status and compares size, mode, and mtime. Gitlink entries are dirty
    /// when the submodule's checked-out commit differs from the index object ID.
    /// Direct work is capped by entry count and elapsed duration; exceeding
    /// either bound switches to a cancellable, non-locking `git status` probe.
    nonisolated func gitTrackedChangesSnapshot(
        repository: ResolvedGitRepository
    ) async -> GitTrackedChangesSnapshot {
        let cancellationSignal = WorkspaceChangesCancellationSignal()
        let resolution = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.blockingStatusQueue.async {
                    let resolution = cancellationSignal.withCurrentBinding {
                        gitTrackedChangesSnapshotBlocking(repository: repository)
                    }
                    continuation.resume(returning: resolution)
                }
            }
        } onCancel: {
            cancellationSignal.cancel()
        }
        if let degradationReason = resolution.degradationReason {
            await degradationRecorder.record(
                repositoryRoot: repository.workTreeRoot,
                reason: degradationReason
            )
        }
        return resolution.snapshot
    }

    private nonisolated func gitTrackedChangesSnapshotBlocking(
        repository: ResolvedGitRepository
    ) -> GitTrackedChangesResolution {
        let indexPath = Self.joinedPath(root: repository.gitDirectory, relativePath: "index")
        let indexURL = URL(fileURLWithPath: indexPath)
        let indexReadResult = GitIndexDataReader().read(
            at: indexURL,
            maximumByteCount: safetyConfiguration.directIndexByteCount
        )
        if let header = indexReadResult.header {
            if header.entryCount > safetyConfiguration.directFileStatusEntryCount {
                return gitStatusFallbackSnapshot(
                    repository: repository,
                    // The fallback result is authoritative. Omitting signatures
                    // prevents sidebar stat-signature reconciliation from
                    // second-guessing a clean result without a matching
                    // content-only signature.
                    indexSignature: nil,
                    indexContentSignature: nil,
                    reason: .trackedEntryLimit(
                        count: header.entryCount,
                        limit: safetyConfiguration.directFileStatusEntryCount
                    )
                )
            }
            if header.fileByteCount > Int64(safetyConfiguration.directIndexByteCount) {
                return gitStatusFallbackSnapshot(
                    repository: repository,
                    indexSignature: nil,
                    indexContentSignature: nil,
                    reason: .indexByteLimit(
                        count: header.fileByteCount,
                        limit: safetyConfiguration.directIndexByteCount
                    )
                )
            }
        }
        guard let indexData = indexReadResult.data,
              let indexSnapshot = GitIndexSnapshotParser().parse(data: indexData) else {
            return gitStatusFallbackSnapshot(
                repository: repository,
                indexSignature: indexReadResult.data.flatMap {
                    GitIndexSnapshotParser().signature(data: $0)
                } ?? Self.gitIndexFileSignature(indexURL: indexURL),
                indexContentSignature: nil,
                reason: .unreadableIndex
            )
        }

        let scanStart = ContinuousClock.now
        let directScanDeadline = DispatchTime.now()
            + (Double(safetyConfiguration.directFileStatusDurationMilliseconds) / 1_000)
        for entry in indexSnapshot.entries {
            if WorkspaceChangesCancellationSignal.isCurrentCancelled {
                return GitTrackedChangesResolution(
                    snapshot: GitTrackedChangesSnapshot(
                        isDirty: true,
                        indexSignature: nil,
                        indexContentSignature: nil
                    )
                )
            }
            if scanStart.duration(to: ContinuousClock.now) >= safetyConfiguration.directFileStatusDuration {
                return gitStatusFallbackSnapshot(
                    repository: repository,
                    indexSignature: nil,
                    indexContentSignature: nil,
                    reason: .directScanDuration(
                        milliseconds: safetyConfiguration.directFileStatusDurationMilliseconds
                    )
                )
            }
            guard DispatchTime.now() < directScanDeadline else {
                return gitStatusFallbackSnapshot(
                    repository: repository,
                    indexSignature: nil,
                    indexContentSignature: nil,
                    reason: .directScanDuration(
                        milliseconds: safetyConfiguration.directFileStatusDurationMilliseconds
                    )
                )
            }
            let gitlinkMode: UInt32 = 0o160000
            if (entry.mode & 0o170000) == gitlinkMode {
                let gitlinkPath = Self.joinedPath(
                    root: repository.workTreeRoot,
                    relativePath: entry.path
                )
                guard let submoduleRepository = Self.resolveGitRepository(
                    containing: gitlinkPath,
                    deadline: directScanDeadline
                ),
                      submoduleRepository.workTreeRoot == gitlinkPath else {
                    return GitTrackedChangesResolution(
                        snapshot: GitTrackedChangesSnapshot(
                            isDirty: true,
                            indexSignature: indexSnapshot.signature,
                            indexContentSignature: indexSnapshot.contentSignature
                        )
                    )
                }
                if referenceReader.requiresGitPlumbing(
                    repository: submoduleRepository,
                    deadline: directScanDeadline
                ) {
                    return gitStatusFallbackSnapshot(
                        repository: repository,
                        indexSignature: nil,
                        indexContentSignature: nil,
                        reason: .submoduleReferenceBackend
                    )
                }
                guard let submoduleCommit = referenceReader
                    .snapshot(
                        repository: submoduleRepository,
                        deadline: directScanDeadline
                    )
                    .currentCommit else {
                    return GitTrackedChangesResolution(
                        snapshot: GitTrackedChangesSnapshot(
                            isDirty: true,
                            indexSignature: indexSnapshot.signature,
                            indexContentSignature: indexSnapshot.contentSignature
                        )
                    )
                }
                if submoduleCommit.caseInsensitiveCompare(entry.objectID) != .orderedSame {
                    return GitTrackedChangesResolution(
                        snapshot: GitTrackedChangesSnapshot(
                            isDirty: true,
                            indexSignature: indexSnapshot.signature,
                            indexContentSignature: indexSnapshot.contentSignature
                        )
                    )
                }
                continue
            }

            let filePath = Self.joinedPath(root: repository.workTreeRoot, relativePath: entry.path)
            guard let fileStatus = fileStatusReader.status(atPath: filePath) else {
                return GitTrackedChangesResolution(
                    snapshot: GitTrackedChangesSnapshot(
                        isDirty: true,
                        indexSignature: indexSnapshot.signature,
                        indexContentSignature: indexSnapshot.contentSignature
                    )
                )
            }
            let size = Self.gitIndexUInt32Field(fileStatus.size)
            let mtimeSeconds = Self.gitIndexUInt32Field(fileStatus.mtimeSeconds)
            let mtimeNanoseconds = Self.gitIndexUInt32Field(fileStatus.mtimeNanoseconds)
            guard let mode = Self.gitIndexComparableMode(for: mode_t(fileStatus.mode)) else {
                return GitTrackedChangesResolution(
                    snapshot: GitTrackedChangesSnapshot(
                        isDirty: true,
                        indexSignature: indexSnapshot.signature,
                        indexContentSignature: indexSnapshot.contentSignature
                    )
                )
            }
            if size != entry.size ||
                mode != entry.mode ||
                mtimeSeconds != entry.mtimeSeconds ||
                mtimeNanoseconds != entry.mtimeNanoseconds {
                return GitTrackedChangesResolution(
                    snapshot: GitTrackedChangesSnapshot(
                        isDirty: true,
                        indexSignature: indexSnapshot.signature,
                        indexContentSignature: indexSnapshot.contentSignature
                    )
                )
            }
        }

        return GitTrackedChangesResolution(
            snapshot: GitTrackedChangesSnapshot(
                isDirty: false,
                indexSignature: indexSnapshot.signature,
                indexContentSignature: indexSnapshot.contentSignature
            )
        )
    }

    private nonisolated func gitStatusFallbackSnapshot(
        repository: ResolvedGitRepository,
        indexSignature: String?,
        indexContentSignature: String?,
        reason: GitMetadataDegradationReason
    ) -> GitTrackedChangesResolution {
        let isDirty = WorkspaceChangesCancellationSignal.isCurrentCancelled
            ? true
            : dirtyStatusReader.isDirty(workTreeRoot: repository.workTreeRoot) ?? true
        return GitTrackedChangesResolution(
            snapshot: GitTrackedChangesSnapshot(
                isDirty: isDirty,
                indexSignature: indexSignature,
                indexContentSignature: indexContentSignature
            ),
            degradationReason: reason
        )
    }

    /// Parses a git `index` file (versions 2, 3, and 4) into a snapshot.
    ///
    /// Handles v3 extended flags, v4 path prefix-compression, assume-unchanged
    /// and skip-worktree exclusion, and entry padding. Returns `nil` for an
    /// absent, truncated, or unsupported-version index.
    nonisolated static func gitIndexSnapshot(indexURL: URL) -> GitIndexSnapshot? {
        let result = GitIndexDataReader().read(
            at: indexURL,
            maximumByteCount: 32 * 1_024 * 1_024
        )
        return result.data.flatMap { GitIndexSnapshotParser().parse(data: $0) }
    }

    /// An FNV-1a content signature over each entry's path, mode, and object ID
    /// (stat-independent), used to detect tracked-content changes across index
    /// rewrites.
    nonisolated static func gitIndexContentSignature(entries: [GitIndexEntryStat]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037

        func appendByte(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }

        func appendUInt32(_ value: UInt32) {
            appendByte(UInt8((value >> 24) & 0xff))
            appendByte(UInt8((value >> 16) & 0xff))
            appendByte(UInt8((value >> 8) & 0xff))
            appendByte(UInt8(value & 0xff))
        }

        func appendString(_ value: String) {
            for byte in value.utf8 {
                appendByte(byte)
            }
        }

        appendUInt32(UInt32(truncatingIfNeeded: entries.count))
        for entry in entries {
            appendString(entry.path)
            appendByte(0)
            appendUInt32(entry.mode)
            appendByte(0)
            appendString(entry.objectID)
            appendByte(0)
        }
        return gitIndexFixedWidthHexString(hash)
    }

    private nonisolated static func gitIndexHexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var encoded: [UInt8] = []
        encoded.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            encoded.append(gitIndexHexAlphabet[Int(byte >> 4)])
            encoded.append(gitIndexHexAlphabet[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private nonisolated static func gitIndexFixedWidthHexString(_ value: UInt64) -> String {
        var encoded = Array(repeating: UInt8(ascii: "0"), count: 16)
        var remaining = value
        for index in stride(from: 15, through: 0, by: -1) {
            encoded[index] = gitIndexHexAlphabet[Int(remaining & 0x0f)]
            remaining >>= 4
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    /// Maps a stat mode to the git index mode word for comparison
    /// (regular/executable file or symlink), or `nil` for other file types.
    nonisolated static func gitIndexComparableMode(for statMode: mode_t) -> UInt32? {
        let type = statMode & mode_t(S_IFMT)
        switch type {
        case mode_t(S_IFREG):
            return (statMode & 0o111) == 0 ? 0o100644 : 0o100755
        case mode_t(S_IFLNK):
            return 0o120000
        default:
            return nil
        }
    }

    /// Truncates any integer to the 32-bit field width git records in the index.
    nonisolated static func gitIndexUInt32Field<T: BinaryInteger>(_ value: T) -> UInt32 {
        UInt32(truncatingIfNeeded: UInt64(truncatingIfNeeded: value))
    }

    /// Whether an index entry path is one git would accept: repository-relative
    /// (not absolute) and free of `..` traversal components. An index containing
    /// anything else is treated as malformed.
    nonisolated static func isValidIndexEntryPath(_ path: String) -> Bool {
        guard !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/").contains("..")
    }

    /// The raw index trailing-20-byte checksum as hex, or `nil` when the index
    /// is absent/too small. Used as a fallback signature when the index cannot
    /// be parsed into entries.
    nonisolated static func gitIndexFileSignature(indexURL: URL) -> String? {
        let descriptor = Darwin.open(indexURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var status = Darwin.stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size >= 20 else { return nil }
        var filesystem = statfs()
        guard Darwin.fstatfs(descriptor, &filesystem) == 0,
              (UInt64(filesystem.f_flags) & UInt64(MNT_LOCAL)) != 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 20)
        let readCount = bytes.withUnsafeMutableBytes { buffer in
            Darwin.pread(descriptor, buffer.baseAddress, buffer.count, status.st_size - 20)
        }
        guard readCount == bytes.count else { return nil }
        return gitIndexHexString(bytes)
    }

    /// Decodes a git index v4 path strip-length varint, advancing `offset`.
    nonisolated static func readGitIndexV4PathStripLength(
        _ bytes: [UInt8],
        offset: inout Int
    ) -> Int? {
        guard offset < bytes.count else { return nil }
        var byte = bytes[offset]
        offset += 1
        var value = Int(byte & 0x7f)
        while (byte & 0x80) != 0 {
            guard offset < bytes.count else { return nil }
            // Git's index v4 path compression uses varint.c's encode/decode pair.
            // Continuation bytes increment the accumulated value before shifting.
            value += 1
            byte = bytes[offset]
            offset += 1
            value = (value << 7) + Int(byte & 0x7f)
        }
        return value
    }

    /// Reads a big-endian `UInt16` at `offset`.
    nonisolated static func readBigEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    /// Reads a big-endian `UInt32` at `offset`.
    nonisolated static func readBigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) |
            (UInt32(bytes[offset + 1]) << 16) |
            (UInt32(bytes[offset + 2]) << 8) |
            UInt32(bytes[offset + 3])
    }
}
