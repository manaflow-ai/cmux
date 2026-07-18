import Darwin
import Foundation

extension AgentHibernationTranscriptGuard {
    private static let transcriptScanChunkBytes = 64 * 1024

    private struct StableRegularFileReader {
        let path: String
        let handle: FileHandle
        let initialPathStatus: stat
        let initialDescriptorStatus: stat
        let initialPathVersion: TeardownTranscriptFileVersion
        let initialDescriptorVersion: TeardownTranscriptFileVersion
    }

    private enum TranscriptLineScanResult {
        case completed
        case decided(Bool)
        case failed
    }

    static func synchronizeRegularFileAndContainingDirectory(
        atPath path: String
    ) -> Bool {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var initialStatus = stat()
        guard fstat(descriptor, &initialStatus) == 0,
              regularOwnedSingleLink(initialStatus),
              Self.path(path, stillNames: initialStatus),
              fsync(descriptor) == 0 else {
            return false
        }
        var synchronizedStatus = stat()
        guard fstat(descriptor, &synchronizedStatus) == 0,
              sameStableFile(synchronizedStatus, initialStatus),
              Self.path(path, stillNames: synchronizedStatus),
              synchronizeContainingDirectory(atPath: path) else {
            return false
        }
        var finalStatus = stat()
        return fstat(descriptor, &finalStatus) == 0
            && sameStableFile(finalStatus, synchronizedStatus)
            && Self.path(path, stillNames: finalStatus)
    }

    static func synchronizeContainingDirectory(atPath path: String) -> Bool {
        let directoryPath = (path as NSString).deletingLastPathComponent
        return synchronizeDirectory(atPath: directoryPath)
    }

    static func synchronizeDirectory(atPath directoryPath: String) -> Bool {
        let descriptor = Darwin.open(
            directoryPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return false }
        let result = fsync(descriptor)
        Darwin.close(descriptor)
        return result == 0
    }

    static func durablyRemoveRecoverySnapshot(
        atPath snapshotPath: String,
        afterSynchronizingLivePath livePath: String? = nil,
        expectedSnapshotVersion: TeardownTranscriptFileVersion? = nil
    ) -> Bool {
        if let livePath,
           !synchronizeRegularFileAndContainingDirectory(atPath: livePath) {
            return false
        }
        let snapshotURL = URL(fileURLWithPath: snapshotPath)
        let filename = snapshotURL.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
            return false
        }
        let directoryDescriptor = Darwin.open(
            snapshotURL.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else { return false }
        defer { Darwin.close(directoryDescriptor) }
        let snapshotDescriptor = openat(
            directoryDescriptor,
            filename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        if snapshotDescriptor < 0 {
            return errno == ENOENT && fsync(directoryDescriptor) == 0
        }
        defer { Darwin.close(snapshotDescriptor) }
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(snapshotDescriptor, &descriptorStatus) == 0,
              regularOwnedSingleLink(descriptorStatus),
              fstatat(
                directoryDescriptor,
                filename,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              regularOwnedSingleLink(pathStatus),
              sameStableFile(pathStatus, descriptorStatus),
              expectedSnapshotVersion.map({
                regularFileVersion(forDescriptor: snapshotDescriptor) == $0
              }) ?? true,
              fsync(snapshotDescriptor) == 0 else {
            return false
        }
        var finalDescriptorStatus = stat()
        var finalPathStatus = stat()
        guard fstat(snapshotDescriptor, &finalDescriptorStatus) == 0,
              sameStableFile(finalDescriptorStatus, descriptorStatus),
              fstatat(
                directoryDescriptor,
                filename,
                &finalPathStatus,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              sameStableFile(finalPathStatus, finalDescriptorStatus),
              unlinkat(directoryDescriptor, filename, 0) == 0 else {
            return false
        }
        return fsync(directoryDescriptor) == 0
    }

    static func stableRegularFileVersion(
        atPath path: String,
        fileManager: FileManager = .default
    ) -> TeardownTranscriptFileVersion? {
        guard let reader = openStableRegularFile(atPath: path, fileManager: fileManager) else {
            return nil
        }
        defer { try? reader.handle.close() }
        return stablePathVersion(for: reader, fileManager: fileManager)
    }

    static func copyStableRegularFileBounded(
        from sourcePath: String,
        to destinationPath: String,
        maximumBytes: UInt64,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let source = openStableRegularFile(
            atPath: sourcePath,
            fileManager: fileManager
        ), source.initialDescriptorVersion.size <= maximumBytes else {
            return false
        }
        defer { try? source.handle.close() }
        let destinationDescriptor = Darwin.open(
            destinationPath,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard destinationDescriptor >= 0 else { return false }
        var shouldRemoveDestination = true
        defer {
            Darwin.close(destinationDescriptor)
            if shouldRemoveDestination { _ = Darwin.unlink(destinationPath) }
        }

        var copiedBytes: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: transcriptScanChunkBytes)
        while true {
            guard copiedBytes <= maximumBytes else { return false }
            let remaining = maximumBytes - copiedBytes
            let requested = remaining == 0
                ? 1
                : Int(min(UInt64(buffer.count), remaining))
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    source.handle.fileDescriptor,
                    bytes.baseAddress,
                    requested
                )
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                return false
            }
            if readCount == 0 { break }
            guard UInt64(readCount) <= maximumBytes - copiedBytes else {
                return false
            }
            var written = 0
            while written < readCount {
                let writeCount = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destinationDescriptor,
                        bytes.baseAddress?.advanced(by: written),
                        readCount - written
                    )
                }
                if writeCount < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard writeCount > 0 else { return false }
                written += writeCount
            }
            copiedBytes += UInt64(readCount)
        }
        guard copiedBytes == source.initialDescriptorVersion.size,
              stablePathVersion(for: source, fileManager: fileManager) != nil,
              fchmod(destinationDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
              fsync(destinationDescriptor) == 0 else {
            return false
        }
        var destinationStatus = stat()
        guard fstat(destinationDescriptor, &destinationStatus) == 0,
              regularOwnedSingleLink(destinationStatus),
              UInt64(destinationStatus.st_size) == copiedBytes,
              destinationStatus.st_mode & mode_t(0o777) == mode_t(0o600),
              path(destinationPath, stillNames: destinationStatus),
              synchronizeContainingDirectory(atPath: destinationPath) else {
            return false
        }
        var finalDestinationStatus = stat()
        guard fstat(destinationDescriptor, &finalDestinationStatus) == 0,
              sameStableFile(finalDestinationStatus, destinationStatus),
              path(destinationPath, stillNames: finalDestinationStatus) else {
            return false
        }
        shouldRemoveDestination = false
        return true
    }

    static func copyStableRegularFileBounded(
        from sourcePath: String,
        toExistingDescriptor destinationDescriptor: Int32,
        expectedDestinationPath destinationPath: String,
        maximumBytes: UInt64,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let source = openStableRegularFile(
            atPath: sourcePath,
            fileManager: fileManager
        ), source.initialDescriptorVersion.size <= maximumBytes else {
            return false
        }
        defer { try? source.handle.close() }
        var initialDestinationStatus = stat()
        guard fstat(destinationDescriptor, &initialDestinationStatus) == 0,
              regularOwnedSingleLink(initialDestinationStatus),
              initialDestinationStatus.st_size == 0,
              path(destinationPath, stillNames: initialDestinationStatus),
              ftruncate(destinationDescriptor, 0) == 0,
              lseek(destinationDescriptor, 0, SEEK_SET) == 0 else {
            return false
        }

        var copiedBytes: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: transcriptScanChunkBytes)
        while true {
            guard copiedBytes <= maximumBytes else { return false }
            let remaining = maximumBytes - copiedBytes
            let requested = remaining == 0
                ? 1
                : Int(min(UInt64(buffer.count), remaining))
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    source.handle.fileDescriptor,
                    bytes.baseAddress,
                    requested
                )
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                return false
            }
            if readCount == 0 { break }
            guard UInt64(readCount) <= maximumBytes - copiedBytes else {
                return false
            }
            var written = 0
            while written < readCount {
                let writeCount = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destinationDescriptor,
                        bytes.baseAddress?.advanced(by: written),
                        readCount - written
                    )
                }
                if writeCount < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard writeCount > 0 else { return false }
                written += writeCount
            }
            copiedBytes += UInt64(readCount)
        }
        guard copiedBytes == source.initialDescriptorVersion.size,
              stablePathVersion(for: source, fileManager: fileManager) != nil,
              fchmod(destinationDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
              fsync(destinationDescriptor) == 0 else {
            return false
        }
        var destinationStatus = stat()
        guard fstat(destinationDescriptor, &destinationStatus) == 0,
              regularOwnedSingleLink(destinationStatus),
              UInt64(destinationStatus.st_size) == copiedBytes,
              destinationStatus.st_dev == initialDestinationStatus.st_dev,
              destinationStatus.st_ino == initialDestinationStatus.st_ino,
              destinationStatus.st_mode & mode_t(0o777) == mode_t(0o600),
              path(destinationPath, stillNames: destinationStatus),
              synchronizeContainingDirectory(atPath: destinationPath) else {
            return false
        }
        var finalDestinationStatus = stat()
        return fstat(destinationDescriptor, &finalDestinationStatus) == 0
            && sameStableFile(finalDestinationStatus, destinationStatus)
            && path(destinationPath, stillNames: finalDestinationStatus)
    }

    private static func regularOwnedSingleLink(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
            && status.st_uid == geteuid()
            && status.st_nlink == 1
            && status.st_size >= 0
    }

    static func sameStableFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_mode & S_IFMT == S_IFREG
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func path(_ path: String, stillNames descriptorStatus: stat) -> Bool {
        var pathStatus = stat()
        return lstat(path, &pathStatus) == 0
            && regularOwnedSingleLink(pathStatus)
            && sameStableFile(pathStatus, descriptorStatus)
    }

    static func snapshotStillMatchesLive(
        _ snapshot: TeardownTranscriptSnapshot,
        fileManager: FileManager = .default
    ) -> TeardownTranscriptSnapshot? {
        guard let liveFileVersion = matchingLiveFileVersion(
            snapshot.transcriptPath,
            snapshot.snapshotPath,
            fileManager: fileManager
        ) else {
            return nil
        }
        return TeardownTranscriptSnapshot(
            transcriptPath: snapshot.transcriptPath,
            snapshotPath: snapshot.snapshotPath,
            liveFileVersion: liveFileVersion,
            guardedProcessIdentities: snapshot.guardedProcessIdentities,
            hasUncapturedGuardedProcesses: snapshot.hasUncapturedGuardedProcesses
        )
    }

    static func liveFileVersionStillMatches(
        _ snapshot: TeardownTranscriptSnapshot,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let expectedVersion = snapshot.liveFileVersion,
              let provenVersion = stablePrefixMatch(
                containerPath: snapshot.transcriptPath,
                prefixPath: snapshot.snapshotPath,
                requireEqualSize: true,
                fileManager: fileManager
              ) else {
            return false
        }
        // Metadata remains an identity/generation fence, while the streamed
        // comparison proves a same-size rewrite did not restore those values.
        return provenVersion == expectedVersion
    }

    static func matchingLiveFileVersion(
        _ lhsPath: String,
        _ rhsPath: String,
        fileManager: FileManager
    ) -> TeardownTranscriptFileVersion? {
        stablePrefixMatch(
            containerPath: lhsPath,
            prefixPath: rhsPath,
            requireEqualSize: true,
            fileManager: fileManager
        )
    }

    static func file(
        atPath containerPath: String,
        stablyContainsPrefixAtPath prefixPath: String,
        fileManager: FileManager = .default
    ) -> Bool {
        stablePrefixMatch(
            containerPath: containerPath,
            prefixPath: prefixPath,
            requireEqualSize: false,
            fileManager: fileManager
        ) != nil
    }

    static func boundedTranscriptHasConversationTurns(
        atPath path: String,
        fileManager: FileManager = .default,
        maxScannedLineBytes: Int,
        maxScannedBytes: Int = 64 * 1024 * 1024
    ) -> Bool {
        let result = scanRegularTranscriptLines(
            atPath: path,
            fileManager: fileManager,
            maxScannedLineBytes: maxScannedLineBytes,
            maxScannedBytes: maxScannedBytes,
            skipOversizedLines: true
        ) { line in
            lineDataContainsConversationTurn(line) ? true : nil
        }
        guard case .decided(let found) = result else { return false }
        return found
    }

    static func boundedTranscriptContainsOnlyNonProtectiveMetadata(
        atPath path: String,
        fileManager: FileManager = .default,
        maxScannedLineBytes: Int,
        maxScannedBytes: Int = 64 * 1024 * 1024
    ) -> Bool {
        var sawMetadata = false
        let result = scanRegularTranscriptLines(
            atPath: path,
            fileManager: fileManager,
            maxScannedLineBytes: maxScannedLineBytes,
            maxScannedBytes: maxScannedBytes,
            skipOversizedLines: false
        ) { line in
            lineDataIsNonProtectiveMetadata(line, sawMetadata: &sawMetadata) ? nil : false
        }
        switch result {
        case .completed:
            // Empty and whitespace-only regular files are valid evidence of an
            // in-place truncation. The line handler returns false for malformed
            // nonempty bytes, so completing without metadata is still safe.
            return true
        case .decided(let decision):
            return decision
        case .failed:
            return false
        }
    }

    private static func stablePrefixMatch(
        containerPath: String,
        prefixPath: String,
        requireEqualSize: Bool,
        fileManager: FileManager
    ) -> TeardownTranscriptFileVersion? {
        guard let container = openStableRegularFile(
            atPath: containerPath,
            fileManager: fileManager
        ), let prefix = openStableRegularFile(
            atPath: prefixPath,
            fileManager: fileManager
        ) else {
            return nil
        }
        defer {
            try? container.handle.close()
            try? prefix.handle.close()
        }

        let containerSize = container.initialDescriptorVersion.size
        let prefixSize = prefix.initialDescriptorVersion.size
        guard prefixSize <= maximumProtectedTranscriptBytes,
              containerSize >= prefixSize,
              !requireEqualSize || containerSize == prefixSize else {
            return nil
        }

        var remaining = prefixSize
        while remaining > 0 {
            let requested = Int(min(UInt64(transcriptScanChunkBytes), remaining))
            let containerChunk: Data
            let prefixChunk: Data
            do {
                containerChunk = try readFullChunk(container.handle, upToCount: requested)
                prefixChunk = try readFullChunk(prefix.handle, upToCount: requested)
            } catch {
                return nil
            }
            guard containerChunk.count == requested,
                  prefixChunk.count == requested,
                  containerChunk == prefixChunk else {
                return nil
            }
            remaining -= UInt64(requested)
        }

        guard let finalContainerVersion = stablePathVersion(
            for: container,
            fileManager: fileManager
        ), stablePathVersion(for: prefix, fileManager: fileManager) != nil else {
            return nil
        }
        return finalContainerVersion
    }

    private static func openStableRegularFile(
        atPath path: String,
        fileManager: FileManager
    ) -> StableRegularFileReader? {
        // Check the path's own type before opening. O_NOFOLLOW closes the race
        // where a regular path is swapped to a symlink after that check, while
        // O_NONBLOCK prevents a swapped FIFO from hanging the caller.
        var initialPathStatus = stat()
        guard lstat(path, &initialPathStatus) == 0,
              regularOwnedSingleLink(initialPathStatus),
              let pathVersion = regularFileVersion(forStatus: initialPathStatus) else {
            return nil
        }
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        var initialDescriptorStatus = stat()
        guard fstat(descriptor, &initialDescriptorStatus) == 0,
              regularOwnedSingleLink(initialDescriptorStatus),
              sameStableFile(initialDescriptorStatus, initialPathStatus),
              let descriptorVersion = regularFileVersion(forStatus: initialDescriptorStatus),
              descriptorVersion == pathVersion else {
            Darwin.close(descriptor)
            return nil
        }
        return StableRegularFileReader(
            path: path,
            handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
            initialPathStatus: initialPathStatus,
            initialDescriptorStatus: initialDescriptorStatus,
            initialPathVersion: pathVersion,
            initialDescriptorVersion: descriptorVersion
        )
    }

    private static func stablePathVersion(
        for reader: StableRegularFileReader,
        fileManager: FileManager
    ) -> TeardownTranscriptFileVersion? {
        var finalDescriptorStatus = stat()
        var finalPathStatus = stat()
        guard fstat(reader.handle.fileDescriptor, &finalDescriptorStatus) == 0,
              lstat(reader.path, &finalPathStatus) == 0,
              regularOwnedSingleLink(finalDescriptorStatus),
              regularOwnedSingleLink(finalPathStatus),
              sameStableFile(finalDescriptorStatus, reader.initialDescriptorStatus),
              sameStableFile(finalPathStatus, reader.initialPathStatus),
              sameStableFile(finalPathStatus, finalDescriptorStatus),
              let finalDescriptorVersion = regularFileVersion(
                forStatus: finalDescriptorStatus
              ), finalDescriptorVersion == reader.initialDescriptorVersion,
              let finalPathVersion = regularFileVersion(
                forStatus: finalPathStatus
              ), finalPathVersion == reader.initialPathVersion else {
            return nil
        }
        return finalPathVersion
    }

    // read(upToCount:) may legally return short reads (network/FUSE volumes);
    // unaligned chunks would make byte-identical files compare unequal and
    // permanently forfeit hibernation on those systems.
    private static func readFullChunk(_ handle: FileHandle, upToCount count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let piece = try handle.read(upToCount: count - data.count),
                  !piece.isEmpty else {
                break
            }
            data.append(piece)
        }
        return data
    }

    private static func scanRegularTranscriptLines(
        atPath path: String,
        fileManager: FileManager,
        maxScannedLineBytes: Int,
        maxScannedBytes: Int,
        skipOversizedLines: Bool,
        lineHandler: (Data) -> Bool?
    ) -> TranscriptLineScanResult {
        guard maxScannedLineBytes >= 0,
              maxScannedBytes > 0,
              let reader = openStableRegularFile(atPath: path, fileManager: fileManager) else {
            return .failed
        }
        defer { try? reader.handle.close() }

        func stableResult(_ result: TranscriptLineScanResult) -> TranscriptLineScanResult {
            guard case .failed = result else {
                return stablePathVersion(for: reader, fileManager: fileManager) != nil
                    ? result
                    : .failed
            }
            return .failed
        }

        let initialSize = reader.initialDescriptorVersion.size
        let readLimit = min(initialSize, UInt64(maxScannedBytes))
        var bytesRead: UInt64 = 0
        var buffered = Data()
        var discardingOversizedLine = false

        func finishAtEndOfInput() -> TranscriptLineScanResult {
            if discardingOversizedLine {
                return skipOversizedLines ? .completed : .failed
            }
            guard buffered.count <= maxScannedLineBytes else {
                return skipOversizedLines ? .completed : .failed
            }
            if let decision = lineHandler(buffered) {
                return .decided(decision)
            }
            return .completed
        }

        while bytesRead < readLimit {
            let requested = Int(min(UInt64(transcriptScanChunkBytes), readLimit - bytesRead))
            let chunk: Data
            do {
                chunk = try reader.handle.read(upToCount: requested) ?? Data()
            } catch {
                return .failed
            }
            if chunk.isEmpty {
                return stableResult(finishAtEndOfInput())
            }
            bytesRead += UInt64(chunk.count)

            var remainderStart = chunk.startIndex
            if discardingOversizedLine {
                guard let newlineIndex = chunk[remainderStart...].firstIndex(of: 10) else {
                    continue
                }
                remainderStart = chunk.index(after: newlineIndex)
                discardingOversizedLine = false
            }

            buffered.append(contentsOf: chunk[remainderStart...])
            var cursor = buffered.startIndex
            while cursor < buffered.endIndex,
                  let newlineIndex = buffered[cursor...].firstIndex(of: 10) {
                let line = buffered[cursor..<newlineIndex]
                if line.count > maxScannedLineBytes {
                    guard skipOversizedLines else { return .failed }
                } else if let decision = lineHandler(Data(line)) {
                    return stableResult(.decided(decision))
                }
                cursor = buffered.index(after: newlineIndex)
            }
            if cursor > buffered.startIndex {
                // Compact once per input chunk, never once per JSONL record.
                buffered.removeSubrange(buffered.startIndex..<cursor)
            }
            if buffered.count > maxScannedLineBytes {
                guard skipOversizedLines else { return .failed }
                buffered.removeAll(keepingCapacity: true)
                discardingOversizedLine = true
            }
        }

        guard initialSize <= UInt64(maxScannedBytes) else {
            return .failed
        }
        return stableResult(finishAtEndOfInput())
    }

    private static func lineDataContainsConversationTurn(_ data: Data) -> Bool {
        guard !data.isEmpty,
              data.range(of: Data(#""type""#.utf8)) != nil,
              (data.range(of: Data(#""user""#.utf8)) != nil ||
                  data.range(of: Data(#""assistant""#.utf8)) != nil),
              String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return false
        }
        return type == "user" || type == "assistant"
    }

    private static func lineDataIsNonProtectiveMetadata(
        _ data: Data,
        sawMetadata: inout Bool
    ) -> Bool {
        guard let line = String(data: data, encoding: .utf8) else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
              let type = object["type"] as? String else {
            return false
        }
        guard type == "last-prompt" || type == "ai-title" || type == "mode" else {
            return false
        }
        sawMetadata = true
        return true
    }

    static func regularFileVersion(
        forDescriptor descriptor: Int32
    ) -> TeardownTranscriptFileVersion? {
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG,
              fileStatus.st_size >= 0 else {
            return nil
        }
        return regularFileVersion(forStatus: fileStatus)
    }

    private static func regularFileVersion(
        forStatus fileStatus: stat
    ) -> TeardownTranscriptFileVersion? {
        guard fileStatus.st_mode & S_IFMT == S_IFREG,
              fileStatus.st_size >= 0 else {
            return nil
        }
        let modificationDate = Date(
            timeIntervalSince1970: TimeInterval(fileStatus.st_mtimespec.tv_sec) +
                TimeInterval(fileStatus.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return TeardownTranscriptFileVersion(
            fileNumber: UInt64(fileStatus.st_ino),
            size: UInt64(fileStatus.st_size),
            modificationDate: modificationDate
        )
    }
}
