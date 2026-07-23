import Foundation

/// Computes bounded in-process metadata for one untracked file.
struct WorkspaceUntrackedFileInspector: Sendable {
    static let maximumReadByteCount = 10 * 1024 * 1024
    static let binaryScanByteCount = 8 * 1024
    private static let readChunkByteCount = 64 * 1024

    func inspect(path: String, repoRoot: String) -> WorkspaceChangedFile? {
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

        while readByteCount < Self.maximumReadByteCount {
            let remaining = Self.maximumReadByteCount - readByteCount
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
            if binaryRemaining > 0,
               chunk.prefix(binaryRemaining).contains(0) {
                isBinary = true
                break
            }
            newlineCount += chunk.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
            readByteCount += chunk.count
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
        return WorkspaceChangedFile(
            path: path,
            oldPath: nil,
            status: .untracked,
            additions: additions,
            deletions: 0,
            isBinary: isBinary
        )
    }
}
