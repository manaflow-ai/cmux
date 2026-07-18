import Darwin
import Foundation

extension AgentHibernationTranscriptGuard {
    private static let transcriptScanChunkBytes = 64 * 1024

    private struct StableRegularFileReader {
        let path: String
        let handle: FileHandle
        let initialPathVersion: TeardownTranscriptFileVersion
        let initialDescriptorVersion: TeardownTranscriptFileVersion
    }

    private enum TranscriptLineScanResult {
        case completed
        case decided(Bool)
        case failed
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
            liveFileVersion: liveFileVersion
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
            return sawMetadata
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
        guard containerSize >= prefixSize,
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
        guard let pathVersion = regularFileVersion(atPath: path, fileManager: fileManager) else {
            return nil
        }
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        guard let descriptorVersion = regularFileVersion(forDescriptor: descriptor),
              descriptorVersion.fileNumber == pathVersion.fileNumber,
              descriptorVersion.size == pathVersion.size else {
            Darwin.close(descriptor)
            return nil
        }
        return StableRegularFileReader(
            path: path,
            handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
            initialPathVersion: pathVersion,
            initialDescriptorVersion: descriptorVersion
        )
    }

    private static func stablePathVersion(
        for reader: StableRegularFileReader,
        fileManager: FileManager
    ) -> TeardownTranscriptFileVersion? {
        guard let finalDescriptorVersion = regularFileVersion(
            forDescriptor: reader.handle.fileDescriptor
        ), finalDescriptorVersion == reader.initialDescriptorVersion,
              let finalPathVersion = regularFileVersion(
                atPath: reader.path,
                fileManager: fileManager
              ), finalPathVersion == reader.initialPathVersion,
              finalDescriptorVersion.fileNumber == finalPathVersion.fileNumber,
              finalDescriptorVersion.size == finalPathVersion.size else {
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
                return finishAtEndOfInput()
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
                    return .decided(decision)
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
        return finishAtEndOfInput()
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

    private static func regularFileVersion(
        atPath path: String,
        fileManager: FileManager
    ) -> TeardownTranscriptFileVersion? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return TeardownTranscriptFileVersion(
            fileNumber: fileNumber,
            size: size,
            modificationDate: modificationDate
        )
    }

    private static func regularFileVersion(
        forDescriptor descriptor: Int32
    ) -> TeardownTranscriptFileVersion? {
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG,
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
