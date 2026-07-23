import Foundation

/// Computes bounded in-process metadata for one untracked file.
struct WorkspaceUntrackedFileInspector: Sendable {
    static let maximumReadByteCount = 10 * 1024 * 1024
    static let maximumAggregateReadByteCount = 64 * 1024 * 1024
    static let binaryScanByteCount = 8 * 1024
    private static let readChunkByteCount = 64 * 1024

    private struct FileInspection {
        let file: WorkspaceChangedFile
        let readByteCount: Int
    }

    private let perFileReadByteCount: Int
    private let aggregateReadByteCount: Int

    init(
        perFileReadByteCount: Int = Self.maximumReadByteCount,
        aggregateReadByteCount: Int = Self.maximumAggregateReadByteCount
    ) {
        self.perFileReadByteCount = max(0, perFileReadByteCount)
        self.aggregateReadByteCount = max(0, aggregateReadByteCount)
    }

    func inspect(path: String, repoRoot: String) -> WorkspaceChangedFile? {
        inspect(
            path: path,
            repoRoot: repoRoot,
            maximumReadByteCount: perFileReadByteCount
        )?.file
    }

    func inspect(paths: [String], repoRoot: String) -> [WorkspaceChangedFile]? {
        var remainingByteCount = aggregateReadByteCount
        var files: [WorkspaceChangedFile] = []
        files.reserveCapacity(paths.count)

        for path in paths {
            guard !Task.isCancelled, remainingByteCount > 0 else {
                files.append(zeroAdditionFile(path: path))
                continue
            }
            guard let inspection = inspect(
                path: path,
                repoRoot: repoRoot,
                maximumReadByteCount: min(perFileReadByteCount, remainingByteCount)
            ) else {
                return nil
            }
            files.append(inspection.file)
            remainingByteCount -= inspection.readByteCount
        }
        return files
    }

    private func inspect(
        path: String,
        repoRoot: String,
        maximumReadByteCount: Int
    ) -> FileInspection? {
        let fileURL = URL(fileURLWithPath: repoRoot, isDirectory: true)
            .appendingPathComponent(path, isDirectory: false)
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size])
            .flatMap { ($0 as? NSNumber)?.int64Value }
        var readByteCount = 0
        var newlineCount = 0
        var lastByte: UInt8?
        var isBinary = false
        var reachedEOF = false

        while readByteCount < maximumReadByteCount, !Task.isCancelled {
            let remaining = maximumReadByteCount - readByteCount
            let chunk: Data
            do {
                chunk = try handle.read(
                    upToCount: min(Self.readChunkByteCount, remaining)
                ) ?? Data()
            } catch {
                return nil
            }
            guard !chunk.isEmpty else {
                reachedEOF = true
                break
            }
            let binaryRemaining = max(0, Self.binaryScanByteCount - readByteCount)
            readByteCount += chunk.count
            if binaryRemaining > 0,
               chunk.prefix(binaryRemaining).contains(0) {
                isBinary = true
                break
            }
            newlineCount += chunk.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
            lastByte = chunk.last
        }

        if let fileSize, Int64(readByteCount) >= fileSize {
            reachedEOF = true
        }
        let additions: Int
        if isBinary {
            additions = 0
        } else {
            additions = newlineCount + (reachedEOF && readByteCount > 0 && lastByte != 0x0A ? 1 : 0)
        }
        return FileInspection(
            file: WorkspaceChangedFile(
                path: path,
                oldPath: nil,
                status: .untracked,
                additions: additions,
                deletions: 0,
                isBinary: isBinary
            ),
            readByteCount: readByteCount
        )
    }

    private func zeroAdditionFile(path: String) -> WorkspaceChangedFile {
        WorkspaceChangedFile(
            path: path,
            oldPath: nil,
            status: .untracked,
            additions: 0,
            deletions: 0,
            isBinary: false
        )
    }
}
