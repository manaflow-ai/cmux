import Foundation

/// Reads a newline-aligned transcript suffix without retaining the discarded prefix.
struct AgentChatTranscriptReader {
    private static let chunkSize = 64 * 1024

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
        return AgentChatTranscriptSlice(
            data: data,
            lineStartOffsets: lineStartOffsets(data: data, startOffset: alignedStart),
            transcriptExtent: fileSize
        )
    }

    private func lineStartOffsets(data: Data, startOffset: UInt64) -> [UInt64] {
        var offsets = [startOffset]
        offsets.reserveCapacity(1 + data.count / 80)
        for (index, byte) in data.enumerated() where byte == 0x0A {
            offsets.append(startOffset + UInt64(index + 1))
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
