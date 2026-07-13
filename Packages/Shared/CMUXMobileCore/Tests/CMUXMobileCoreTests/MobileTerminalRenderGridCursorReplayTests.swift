import Foundation
import Testing
@testable import CMUXMobileCore

@Test func aboveBottomReplayKeepsHybridOutputOnActiveScreenCursorRow() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-window",
        stateSeq: 9,
        columns: 12,
        rows: 3,
        cursor: .init(row: 0, column: 4, visible: false),
        rowSpans: [
            .init(row: 0, column: 0, text: "old-1"),
            .init(row: 1, column: 0, text: "old-2"),
            .init(row: 2, column: 0, text: "old-3"),
        ],
        scrollForwardRows: 2,
        scrollForwardSpans: [
            .init(row: 0, column: 0, text: "new-1"),
            .init(row: 1, column: 0, text: "new-2"),
        ]
    )
    var bytes = frame.vtReplacementBytes()
    bytes.append(Data("\rhybrid".utf8))

    let cursor = ReplayCursorProbe.finalCursor(after: bytes, rows: frame.rows)

    #expect(
        cursor.row == frame.rows - 1,
        "raw output following an above-bottom replay must continue on the reconstructed active screen"
    )
}

@Test func hiddenViewportCursorRestoresItsCapturedRowWithForwardHistory() throws {
    let frame = try decodeCursorFrame(
        row: 0,
        visible: false,
        location: "viewport",
        scrollForwardRows: 2
    )
    var bytes = frame.vtReplacementBytes()
    bytes.append(Data("\rhybrid".utf8))

    let cursor = ReplayCursorProbe.finalCursor(after: bytes, rows: frame.rows)

    #expect(frame.cursor?.location == .viewport)
    #expect(cursor.row == 0)
}

@Test func visibleViewportCursorRestoresItsCapturedRowWithForwardHistory() throws {
    let frame = try decodeCursorFrame(
        row: 1,
        visible: true,
        location: "viewport",
        scrollForwardRows: 2
    )

    let cursor = ReplayCursorProbe.finalCursor(after: frame.vtReplacementBytes(), rows: frame.rows)

    #expect(cursor.row == 1)
}

@Test func belowViewportCursorPreservesReconstructedActiveRow() throws {
    let frame = try decodeCursorFrame(
        row: 0,
        visible: false,
        location: "below_viewport",
        scrollForwardRows: 2
    )
    var bytes = frame.vtReplacementBytes()
    bytes.append(Data("\rhybrid".utf8))

    let cursor = ReplayCursorProbe.finalCursor(after: bytes, rows: frame.rows)

    #expect(frame.cursor?.location == .belowViewport)
    #expect(cursor.row == frame.rows - 1)
}

@Test func aboveViewportCursorPreservesReconstructedActiveRow() throws {
    let frame = try decodeCursorFrame(
        row: 0,
        visible: false,
        location: "above_viewport",
        scrollForwardRows: 2
    )
    var bytes = frame.vtReplacementBytes()
    bytes.append(Data("\rhybrid".utf8))

    let cursor = ReplayCursorProbe.finalCursor(after: bytes, rows: frame.rows)

    #expect(frame.cursor?.location == .aboveViewport)
    #expect(cursor.row == frame.rows - 1)
}

@Test func hiddenAlternateScreenCursorRestoresItsCapturedRow() throws {
    let frame = try decodeCursorFrame(
        row: 1,
        visible: false,
        location: "viewport",
        activeScreen: "alternate"
    )

    let cursor = ReplayCursorProbe.finalCursor(after: frame.vtReplacementBytes(), rows: frame.rows)

    #expect(cursor.row == 1)
}

@Test func previousCursorPayloadWithoutLocationKeepsLegacyForwardReplayBehavior() throws {
    let frame = try decodeCursorFrame(
        row: 0,
        visible: false,
        location: nil,
        scrollForwardRows: 2
    )
    var bytes = frame.vtReplacementBytes()
    bytes.append(Data("\rhybrid".utf8))

    let cursor = ReplayCursorProbe.finalCursor(after: bytes, rows: frame.rows)

    #expect(frame.cursor?.location == nil)
    #expect(cursor.row == frame.rows - 1)
}

private func decodeCursorFrame(
    row: Int,
    visible: Bool,
    location: String?,
    activeScreen: String = "primary",
    scrollForwardRows: Int = 0
) throws -> MobileTerminalRenderGridFrame {
    var cursor: [String: Any] = [
        "row": row,
        "column": 4,
        "visible": visible,
        "style": "block",
        "blinking": false,
    ]
    cursor["location"] = location
    let forwardSpans: [[String: Any]] = (0..<scrollForwardRows).map { row in
        [
            "row": row,
            "column": 0,
            "style_id": 0,
            "text": "new-\(row)",
        ]
    }
    return try MobileTerminalRenderGridFrame.decodeJSONObject([
        "format": MobileTerminalRenderGridFrame.currentFormat,
        "surface_id": "terminal-window",
        "state_seq": 9,
        "columns": 12,
        "rows": 3,
        "cursor": cursor,
        "full": true,
        "styles": [["id": 0]],
        "row_spans": [
            ["row": 0, "column": 0, "style_id": 0, "text": "old-1"],
            ["row": 1, "column": 0, "style_id": 0, "text": "old-2"],
            ["row": 2, "column": 0, "style_id": 0, "text": "old-3"],
        ],
        "active_screen": activeScreen,
        "scrollforward_rows": scrollForwardRows,
        "scrollforward_spans": forwardSpans,
    ])
}

private struct ReplayCursorProbe {
    private(set) var row = 0
    private(set) var column = 0
    let rows: Int

    static func finalCursor(after data: Data, rows: Int) -> ReplayCursorProbe {
        var probe = ReplayCursorProbe(rows: rows)
        probe.consume(Array(data))
        return probe
    }

    private mutating func consume(_ bytes: [UInt8]) {
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x1B:
                index = consumeEscape(bytes, at: index)
            case 0x0D:
                column = 0
                index += 1
            case 0x0A:
                row = min(row + 1, max(rows - 1, 0))
                index += 1
            case 0x20...0x7E:
                column += 1
                index += 1
            default:
                index += 1
            }
        }
    }

    private mutating func consumeEscape(_ bytes: [UInt8], at escapeIndex: Int) -> Int {
        let introducer = escapeIndex + 1
        guard introducer < bytes.count else { return bytes.count }
        if bytes[introducer] == 0x5D {
            return consumeOSC(bytes, at: introducer + 1)
        }
        guard bytes[introducer] == 0x5B else {
            return min(introducer + 1, bytes.count)
        }
        var finalIndex = introducer + 1
        while finalIndex < bytes.count,
              !(0x40...0x7E).contains(bytes[finalIndex]) {
            finalIndex += 1
        }
        guard finalIndex < bytes.count else { return bytes.count }
        let parameters = String(
            decoding: bytes[(introducer + 1)..<finalIndex],
            as: UTF8.self
        )
        applyCSI(parameters: parameters, final: bytes[finalIndex])
        return finalIndex + 1
    }

    private func consumeOSC(_ bytes: [UInt8], at start: Int) -> Int {
        var index = start
        while index < bytes.count {
            if bytes[index] == 0x07 { return index + 1 }
            if bytes[index] == 0x1B,
               index + 1 < bytes.count,
               bytes[index + 1] == 0x5C {
                return index + 2
            }
            index += 1
        }
        return bytes.count
    }

    private mutating func applyCSI(parameters: String, final: UInt8) {
        let values = parameters.split(separator: ";").compactMap { Int($0) }
        switch final {
        case 0x48, 0x66:
            row = min(max((values.first ?? 1) - 1, 0), max(rows - 1, 0))
            column = max((values.dropFirst().first ?? 1) - 1, 0)
        case 0x47:
            column = max((values.first ?? 1) - 1, 0)
        default:
            break
        }
    }
}
