import Foundation

/// Reads a fixed-size transcript suffix without mapping or scanning the file head.
struct AgentChatTranscriptInitialTailReader: Sendable {
    static let defaultMaximumBytes = 4 * 1024 * 1024

    struct Snapshot: Sendable {
        let data: Data
        let fileSize: UInt64
        let retainedStartOffset: UInt64
        let headTruncated: Bool
        let discardsUntilNextNewline: Bool
    }

    func read(path: String, maximumBytes: Int) -> Snapshot? {
        guard maximumBytes > 0,
              let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        let byteBudget = UInt64(maximumBytes)
        let desiredStart = fileSize > byteBudget ? fileSize - byteBudget : 0
        let readStart = desiredStart > 0 ? desiredStart - 1 : 0
        let requestedCount = Int(min(fileSize - readStart, byteBudget + (desiredStart > 0 ? 1 : 0)))
        guard (try? handle.seek(toOffset: readStart)) != nil,
              let bytes = try? readBytes(handle: handle, count: requestedCount) else {
            return nil
        }
        guard desiredStart > 0 else {
            return Snapshot(
                data: bytes,
                fileSize: fileSize,
                retainedStartOffset: 0,
                headTruncated: false,
                discardsUntilNextNewline: false
            )
        }
        guard let guardByte = bytes.first else {
            return Snapshot(
                data: Data(),
                fileSize: fileSize,
                retainedStartOffset: fileSize,
                headTruncated: true,
                discardsUntilNextNewline: true
            )
        }
        if guardByte == 0x0A {
            return Snapshot(
                data: Data(bytes.dropFirst()),
                fileSize: fileSize,
                retainedStartOffset: desiredStart,
                headTruncated: true,
                discardsUntilNextNewline: false
            )
        }
        guard let boundary = bytes.dropFirst().firstIndex(of: 0x0A) else {
            return Snapshot(
                data: Data(),
                fileSize: fileSize,
                retainedStartOffset: fileSize,
                headTruncated: true,
                discardsUntilNextNewline: true
            )
        }
        let retainedStart = bytes.index(after: boundary)
        return Snapshot(
            data: Data(bytes[retainedStart...]),
            fileSize: fileSize,
            retainedStartOffset: readStart + UInt64(retainedStart),
            headTruncated: true,
            discardsUntilNextNewline: false
        )
    }

    private func readBytes(handle: FileHandle, count: Int) throws -> Data {
        var bytes = Data()
        bytes.reserveCapacity(count)
        while bytes.count < count {
            guard let chunk = try handle.read(upToCount: count - bytes.count),
                  !chunk.isEmpty else {
                break
            }
            bytes.append(chunk)
        }
        return bytes
    }
}
