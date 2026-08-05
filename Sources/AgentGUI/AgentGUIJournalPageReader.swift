import CmuxAgentReplica
import Foundation

/// One complete JSONL source record and its stable byte position.
struct AgentGUIJournalSourceLine: Sendable, Equatable {
    let text: String
    let startOffset: Int
    let endOffset: Int
}

struct AgentGUIJournalRawPage: Sendable, Equatable {
    let lines: [AgentGUIJournalSourceLine]
    let startOffset: Int
    let endOffset: Int
    let fileSize: Int
    let hasMoreBefore: Bool
    let hasMoreAfter: Bool
    let readSucceeded: Bool
}

enum AgentGUIJournalPageDirection: Sendable, Equatable {
    case head
    case tail
    case before(Int)
    case after(Int)
}

/// Reads bounded JSONL pages directly from disk. The reader never grows its
/// allocation with journal size and returns only complete source records.
enum AgentGUIJournalPageReader {
    static let maximumRecordByteCount = 8 * 1_024 * 1_024

    static func read(
        path: String,
        direction: AgentGUIJournalPageDirection,
        lineLimit: Int,
        byteLimit: Int,
        recoversOversizedRecords: Bool = true
    ) -> AgentGUIJournalRawPage {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return failurePage()
        }
        defer { try? handle.close() }

        let fileSize = Int((try? handle.seekToEnd()) ?? 0)
        let boundedLineLimit = max(1, lineLimit)
        let boundedByteLimit = max(1, byteLimit)
        switch direction {
        case .head:
            return readForward(
                handle: handle,
                from: 0,
                fileSize: fileSize,
                lineLimit: boundedLineLimit,
                byteLimit: boundedByteLimit
            )
        case .tail:
            return readBackward(
                handle: handle,
                before: fileSize,
                fileSize: fileSize,
                lineLimit: boundedLineLimit,
                byteLimit: boundedByteLimit,
                dropsTrailingPartialLine: true,
                recoversOversizedRecords: recoversOversizedRecords
            )
        case .before(let offset):
            guard (0...fileSize).contains(offset),
                  offset == 0 || isLineBoundary(handle: handle, offset: offset) else {
                return failurePage(fileSize: fileSize)
            }
            return readBackward(
                handle: handle,
                before: offset,
                fileSize: fileSize,
                lineLimit: boundedLineLimit,
                byteLimit: boundedByteLimit,
                dropsTrailingPartialLine: false,
                recoversOversizedRecords: recoversOversizedRecords
            )
        case .after(let offset):
            guard (0...fileSize).contains(offset),
                  offset == 0 || isLineBoundary(handle: handle, offset: offset) else {
                return failurePage(fileSize: fileSize)
            }
            return readForward(
                handle: handle,
                from: offset,
                fileSize: fileSize,
                lineLimit: boundedLineLimit,
                byteLimit: boundedByteLimit
            )
        }
    }

    private static func readForward(
        handle: FileHandle,
        from offset: Int,
        fileSize: Int,
        lineLimit: Int,
        byteLimit: Int
    ) -> AgentGUIJournalRawPage {
        let readEnd = min(fileSize, offset + byteLimit)
        guard let data = read(handle: handle, range: offset..<readEnd) else {
            return failurePage(fileSize: fileSize)
        }
        let allLines = completeLines(in: data, absoluteStart: offset)
        let lines = Array(allLines.prefix(lineLimit))
        if lines.isEmpty, readEnd < fileSize,
           let skippedEnd = scanForwardToLineEnd(handle: handle, from: readEnd, fileSize: fileSize) {
            let oversized = sourceLine(
                handle: handle,
                startOffset: offset,
                endOffset: skippedEnd
            )
            return AgentGUIJournalRawPage(
                lines: [oversized],
                startOffset: offset,
                endOffset: skippedEnd,
                fileSize: fileSize,
                hasMoreBefore: offset > 0,
                hasMoreAfter: skippedEnd < fileSize,
                readSucceeded: true
            )
        }
        let endOffset = lines.last?.endOffset ?? offset
        return AgentGUIJournalRawPage(
            lines: lines,
            startOffset: lines.first?.startOffset ?? offset,
            endOffset: endOffset,
            fileSize: fileSize,
            hasMoreBefore: offset > 0,
            hasMoreAfter: endOffset < fileSize,
            readSucceeded: true
        )
    }

    private static func readBackward(
        handle: FileHandle,
        before offset: Int,
        fileSize: Int,
        lineLimit: Int,
        byteLimit: Int,
        dropsTrailingPartialLine: Bool,
        recoversOversizedRecords: Bool
    ) -> AgentGUIJournalRawPage {
        let readStart = max(0, offset - byteLimit)
        guard let readData = read(handle: handle, range: readStart..<offset) else {
            return failurePage(fileSize: fileSize)
        }
        let endsAtLineBoundary = readData.last == 0x0A
        var data = readData
        var absoluteStart = readStart

        if readStart > 0, !isLineBoundary(handle: handle, offset: readStart) {
            guard let newline = data.firstIndex(of: 0x0A) else {
                let skippedStart = recoversOversizedRecords
                    ? scanBackwardToLineStart(handle: handle, before: readStart)
                    : readStart
                return AgentGUIJournalRawPage(
                    lines: [],
                    startOffset: skippedStart,
                    endOffset: offset,
                    fileSize: fileSize,
                    hasMoreBefore: skippedStart > 0,
                    hasMoreAfter: offset < fileSize,
                    readSucceeded: true
                )
            }
            let next = data.index(after: newline)
            absoluteStart += data.distance(from: data.startIndex, to: next)
            data = Data(data[next...])
        }

        if dropsTrailingPartialLine, data.last != 0x0A {
            if let newline = data.lastIndex(of: 0x0A) {
                data = Data(data[...newline])
            } else {
                data.removeAll(keepingCapacity: false)
            }
        }

        let allLines = completeLines(in: data, absoluteStart: absoluteStart)
        if allLines.isEmpty, readStart > 0 {
            let skippedStart = recoversOversizedRecords
                ? scanBackwardToLineStart(handle: handle, before: readStart)
                : readStart
            if dropsTrailingPartialLine, !endsAtLineBoundary {
                return AgentGUIJournalRawPage(
                    lines: [],
                    startOffset: skippedStart,
                    endOffset: offset,
                    fileSize: fileSize,
                    hasMoreBefore: skippedStart > 0,
                    hasMoreAfter: offset < fileSize,
                    readSucceeded: true
                )
            }
            let oversized = sourceLine(
                handle: handle,
                startOffset: skippedStart,
                endOffset: offset
            )
            return AgentGUIJournalRawPage(
                lines: [oversized],
                startOffset: skippedStart,
                endOffset: offset,
                fileSize: fileSize,
                hasMoreBefore: skippedStart > 0,
                hasMoreAfter: offset < fileSize,
                readSucceeded: true
            )
        }
        let lines = Array(allLines.suffix(lineLimit))
        let startOffset = lines.first?.startOffset ?? offset
        let endOffset = lines.last?.endOffset ?? offset
        return AgentGUIJournalRawPage(
            lines: lines,
            startOffset: startOffset,
            endOffset: endOffset,
            fileSize: fileSize,
            hasMoreBefore: startOffset > 0,
            hasMoreAfter: endOffset < fileSize,
            readSucceeded: true
        )
    }

    private static func read(handle: FileHandle, range: Range<Int>) -> Data? {
        guard !range.isEmpty else { return Data() }
        do {
            try handle.seek(toOffset: UInt64(range.lowerBound))
            return try handle.read(upToCount: range.count) ?? Data()
        } catch {
            return nil
        }
    }

    private static func isLineBoundary(handle: FileHandle, offset: Int) -> Bool {
        guard offset > 0,
              let preceding = read(handle: handle, range: (offset - 1)..<offset) else {
            return offset == 0
        }
        return preceding.first == 0x0A
    }

    private static func scanForwardToLineEnd(handle: FileHandle, from offset: Int, fileSize: Int) -> Int? {
        let scanSize = 64 * 1_024
        var position = offset
        while position < fileSize {
            let end = min(fileSize, position + scanSize)
            guard let data = read(handle: handle, range: position..<end) else { return nil }
            if let newline = data.firstIndex(of: 0x0A) {
                return position + data.distance(from: data.startIndex, to: data.index(after: newline))
            }
            position = end
        }
        return nil
    }

    private static func scanBackwardToLineStart(handle: FileHandle, before offset: Int) -> Int {
        let scanSize = 64 * 1_024
        var end = offset
        while end > 0 {
            let start = max(0, end - scanSize)
            guard let data = read(handle: handle, range: start..<end) else { return 0 }
            if let newline = data.lastIndex(of: 0x0A) {
                return start + data.distance(from: data.startIndex, to: data.index(after: newline))
            }
            end = start
        }
        return 0
    }

    private static func completeLines(in data: Data, absoluteStart: Int) -> [AgentGUIJournalSourceLine] {
        var lines: [AgentGUIJournalSourceLine] = []
        var lineStart = data.startIndex
        for newline in data.indices where data[newline] == 0x0A {
            let relativeStart = data.distance(from: data.startIndex, to: lineStart)
            let relativeEnd = data.distance(from: data.startIndex, to: data.index(after: newline))
            lines.append(AgentGUIJournalSourceLine(
                text: String(decoding: data[lineStart..<newline], as: UTF8.self),
                startOffset: absoluteStart + relativeStart,
                endOffset: absoluteStart + relativeEnd
            ))
            lineStart = data.index(after: newline)
        }
        return lines
    }

    private static func sourceLine(
        handle: FileHandle,
        startOffset: Int,
        endOffset: Int
    ) -> AgentGUIJournalSourceLine {
        let byteCount = max(0, endOffset - startOffset)
        if byteCount <= maximumRecordByteCount,
           var data = read(handle: handle, range: startOffset..<endOffset) {
            if data.last == 0x0A {
                data.removeLast()
            }
            return AgentGUIJournalSourceLine(
                text: String(decoding: data, as: UTF8.self),
                startOffset: startOffset,
                endOffset: endOffset
            )
        }
        let diagnostic = "{\"type\":\"cmux_oversized_record\",\"byte_count\":\(byteCount),\"maximum_supported_byte_count\":\(maximumRecordByteCount)}"
        return AgentGUIJournalSourceLine(
            text: diagnostic,
            startOffset: startOffset,
            endOffset: endOffset
        )
    }

    private static func failurePage(fileSize: Int = 0) -> AgentGUIJournalRawPage {
        AgentGUIJournalRawPage(
            lines: [],
            startOffset: 0,
            endOffset: 0,
            fileSize: fileSize,
            hasMoreBefore: false,
            hasMoreAfter: false,
            readSucceeded: false
        )
    }
}

enum AgentGUIJournalCursorCodec {
    private struct Payload: Codable {
        let version: Int
        let journalID: String
        let byteOffset: Int

        private enum CodingKeys: String, CodingKey {
            case version = "v"
            case journalID = "j"
            case byteOffset = "o"
        }
    }

    static func encode(journalID: JournalID, byteOffset: Int) -> JournalCursor {
        let payload = Payload(version: 1, journalID: journalID.rawValue, byteOffset: byteOffset)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return JournalCursor(rawValue: encoded)
    }

    static func decode(_ cursor: JournalCursor, journalID: JournalID) -> Int? {
        var encoded = cursor.rawValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - encoded.count % 4) % 4
        encoded.append(String(repeating: "=", count: padding))
        guard let data = Data(base64Encoded: encoded),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1,
              payload.journalID == journalID.rawValue,
              payload.byteOffset >= 0 else {
            return nil
        }
        return payload.byteOffset
    }
}
