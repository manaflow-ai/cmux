import Foundation

/// Reads a newline-aligned transcript suffix without retaining the discarded prefix.
struct AgentChatTranscriptReader {
    private static let chunkSize = 64 * 1024

    func read(
        handle: FileHandle,
        fileSize: UInt64,
        maximumBytes: UInt64,
        anchorOffset: UInt64?,
        anchorSequence: Int?
    ) throws -> AgentChatTranscriptSlice {
        let retainedByteCount = min(fileSize, max(1, maximumBytes))
        let requestedStart = fileSize - retainedByteCount
        let usableAnchor = anchorOffset.flatMap { offset -> (UInt64, Int)? in
            guard let anchorSequence, offset <= requestedStart else { return nil }
            return (offset, anchorSequence)
        }
        var startingSequence = usableAnchor?.1 ?? 0
        let countStart = usableAnchor?.0 ?? 0
        try handle.seek(toOffset: countStart)
        startingSequence += try countNewlines(
            handle: handle,
            byteCount: requestedStart - countStart
        )

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
            startingSequence += 1
        }
        return AgentChatTranscriptSlice(
            data: data,
            startOffset: alignedStart,
            startingSequence: startingSequence
        )
    }

    private func countNewlines(handle: FileHandle, byteCount: UInt64) throws -> Int {
        var remaining = byteCount
        var count = 0
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = Int(min(remaining, UInt64(Self.chunkSize)))
            let chunk = try handle.read(upToCount: requested) ?? Data()
            guard !chunk.isEmpty else { break }
            count += chunk.count(where: { $0 == 0x0A })
            remaining -= UInt64(chunk.count)
        }
        return count
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
