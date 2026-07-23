import CryptoKit
import Foundation

/// Reads a newline-aligned transcript suffix without retaining the discarded prefix.
struct AgentChatTranscriptReader {
    private static let chunkSize = 64 * 1024
    private static let maximumRetainedLineCount = 16_384

    func read(
        handle: FileHandle,
        fileSize: UInt64,
        maximumBytes: UInt64
    ) throws -> AgentChatTranscriptSlice {
        let retainedByteCount = min(fileSize, max(1, maximumBytes))
        let requestedStart = fileSize - retainedByteCount

        let startsAtLineBoundary: Bool
        if requestedStart == 0 {
            startsAtLineBoundary = true
        } else {
            try handle.seek(toOffset: requestedStart - 1)
            startsAtLineBoundary = try handle.read(upToCount: 1)?.first == 0x0A
        }
        try handle.seek(toOffset: requestedStart)
        var data = try read(handle: handle, byteCount: retainedByteCount)
        var alignedStart = requestedStart
        if !startsAtLineBoundary, let newline = data.firstIndex(of: 0x0A) {
            let removedByteCount = data.distance(from: data.startIndex, to: newline) + 1
            data.removeSubrange(data.startIndex...newline)
            alignedStart += UInt64(removedByteCount)
        }
        let relativeLineStarts = try retainedLineStartOffsets(data: data)
        let trimmedPrefixCount = relativeLineStarts.first ?? 0
        if trimmedPrefixCount > 0 {
            let trimmedPrefixEnd = data.index(data.startIndex, offsetBy: trimmedPrefixCount)
            data.removeSubrange(data.startIndex..<trimmedPrefixEnd)
        }
        return AgentChatTranscriptSlice(
            data: data,
            lineStartOffsets: relativeLineStarts.map { alignedStart + UInt64($0) },
            transcriptExtent: fileSize
        )
    }

    func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    func matchesContent(
        handle: FileHandle,
        startOffset: UInt64,
        byteCount: UInt64,
        expectedDigest: Data
    ) throws -> Bool {
        try handle.seek(toOffset: startOffset)
        var hasher = SHA256()
        var remaining = byteCount
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = Int(min(remaining, UInt64(Self.chunkSize)))
            guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else {
                return false
            }
            hasher.update(data: chunk)
            remaining -= UInt64(chunk.count)
        }
        return Data(hasher.finalize()) == expectedDigest
    }

    private func retainedLineStartOffsets(data: Data) throws -> [Int] {
        let limit = Self.maximumRetainedLineCount
        var ring = [Int](repeating: 0, count: limit)
        var retainedCount = 1
        var totalCount = 1
        var nextInsertionIndex = 1
        var cancellationCountdown = Self.chunkSize
        for (index, byte) in data.enumerated() {
            cancellationCountdown -= 1
            if cancellationCountdown == 0 {
                try Task.checkCancellation()
                cancellationCountdown = Self.chunkSize
            }
            guard byte == 0x0A else { continue }
            ring[nextInsertionIndex] = index + 1
            nextInsertionIndex = (nextInsertionIndex + 1) % limit
            totalCount += 1
            retainedCount = min(totalCount, limit)
        }
        let firstIndex = totalCount > limit ? nextInsertionIndex : 0
        var offsets: [Int] = []
        offsets.reserveCapacity(retainedCount)
        for index in 0..<retainedCount {
            offsets.append(ring[(firstIndex + index) % limit])
        }
        return offsets
    }

    private func read(handle: FileHandle, byteCount: UInt64) throws -> Data {
        var data = Data()
        data.reserveCapacity(Int(byteCount))
        var remaining = byteCount
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = Int(min(remaining, UInt64(Self.chunkSize)))
            let chunk = try handle.read(upToCount: requested) ?? Data()
            guard !chunk.isEmpty else { break }
            data.append(chunk)
            remaining -= UInt64(chunk.count)
        }
        return data
    }
}
