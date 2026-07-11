import Foundation

extension AgentHibernationTranscriptGuard {
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
              let currentVersion = fileVersion(atPath: snapshot.transcriptPath, fileManager: fileManager) else {
            return false
        }
        return currentVersion == expectedVersion
    }

    static func matchingLiveFileVersion(
        _ lhsPath: String,
        _ rhsPath: String,
        fileManager: FileManager
    ) -> TeardownTranscriptFileVersion? {
        guard let initialLHSVersion = fileVersion(atPath: lhsPath, fileManager: fileManager),
              let initialRHSVersion = fileVersion(atPath: rhsPath, fileManager: fileManager),
              initialLHSVersion.size == initialRHSVersion.size,
              let lhsHandle = FileHandle(forReadingAtPath: lhsPath),
              let rhsHandle = FileHandle(forReadingAtPath: rhsPath) else {
            return nil
        }
        defer {
            try? lhsHandle.close()
            try? rhsHandle.close()
        }

        while true {
            let lhsChunk: Data
            let rhsChunk: Data
            do {
                lhsChunk = try readFullChunk(lhsHandle, upToCount: 64 * 1024)
                rhsChunk = try readFullChunk(rhsHandle, upToCount: 64 * 1024)
            } catch {
                return nil
            }
            guard lhsChunk == rhsChunk else { return nil }
            if lhsChunk.isEmpty { break }
        }

        guard let finalLHSVersion = fileVersion(atPath: lhsPath, fileManager: fileManager),
              let finalRHSVersion = fileVersion(atPath: rhsPath, fileManager: fileManager),
              initialLHSVersion == finalLHSVersion,
              initialRHSVersion == finalRHSVersion else {
            return nil
        }
        return finalLHSVersion
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

    private static func fileVersion(
        atPath path: String,
        fileManager: FileManager
    ) -> TeardownTranscriptFileVersion? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
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
}
