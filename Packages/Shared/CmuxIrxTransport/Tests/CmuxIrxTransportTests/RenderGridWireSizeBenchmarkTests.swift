import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrxTransport

/// Byte cost of a typical agent session on the phone lane: a 120x40 screen
/// with a colorful status area, a spinner that repaints one row per frame and
/// a transcript that grows one line every few frames.
///
/// "legacy" rebuilds the pre-compaction wire shape (whole style table in every
/// delta, every flag and default key spelled out) from the same frames, so the
/// three numbers compare encodings of identical terminal states.
struct RenderGridWireSizeBenchmarkTests {
    private static let columns = 120
    private static let rows = 40
    private static let surfaceID = "8C0A57A4-7F1B-4D0B-9C39-2F4E8B1A6D10"
    private static let epoch = "3E7C1D2A-55B0-4C8F-A1D2-9B7E6F5A4C3B"

    private static let styles: [MobileTerminalRenderGridFrame.Style] = {
        var styles: [MobileTerminalRenderGridFrame.Style] = [
            .init(id: 0, foreground: "#D8D8D8", background: "#1E1E1E"),
        ]
        for id in 1...36 {
            let red = (id * 37) % 256
            let green = (id * 91) % 256
            let blue = (id * 53) % 256
            let foreground: String = String(format: "#%02X%02X%02X", red, green, blue)
            let background: String? = id.isMultiple(of: 5) ? "#2A2A2A" : nil
            styles.append(MobileTerminalRenderGridFrame.Style(
                id: id,
                foreground: foreground,
                background: background,
                foregroundSource: .palette,
                foregroundPaletteIndex: id % 16,
                bold: id.isMultiple(of: 3),
                faint: id.isMultiple(of: 7),
                italic: id.isMultiple(of: 11)
            ))
        }
        return styles
    }()

    private static func screen(frame index: Int) throws -> MobileTerminalRenderGridFrame {
        var spans: [MobileTerminalRenderGridFrame.RowSpan] = []
        for row in 0..<rows {
            let line = row < 34
                ? "⏺ transcript line \(row + index / 4) · tool output with some detail text"
                : "status \(row) │ model · tokens \(index * 17 % 9973) · branch feat/x"
            // Several colored runs per row, like syntax-highlighted output.
            var column = 0
            for (part, text) in line.split(separator: " ").enumerated() where column < columns - 12 {
                let clipped = String(text.prefix(12))
                spans.append(.init(row: row, column: column, styleID: (row + part) % 36 + 1, text: clipped))
                column += clipped.count + 1
            }
        }
        let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"][index % 8]
        spans.append(.init(row: 33, column: 110, styleID: 5, text: spinner))
        return try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: UInt64(10_000 + index),
            appliedInputSequence: 42,
            renderEpoch: epoch,
            renderRevision: UInt64(index + 1),
            columns: columns,
            rows: rows,
            cursor: .init(row: 39, column: 2),
            styles: styles,
            rowSpans: spans,
            modes: [.init(code: 7, on: true), .init(code: 2004, on: true)],
            anchor: .screen,
            historyRows: UInt64(500 + index / 4)
        )
    }

    private static func legacyJSON(_ frame: MobileTerminalRenderGridFrame, fullStyles: [MobileTerminalRenderGridFrame.Style]) throws -> Data {
        func style(_ style: MobileTerminalRenderGridFrame.Style) -> [String: Any] {
            var object: [String: Any] = [
                "id": style.id, "bold": style.bold, "faint": style.faint, "italic": style.italic,
                "underline": style.underline, "blink": style.blink, "inverse": style.inverse,
                "invisible": style.invisible, "strikethrough": style.strikethrough,
                "overline": style.overline,
            ]
            object["foreground"] = style.foreground
            object["background"] = style.background
            object["foreground_source"] = style.foregroundSource?.rawValue
            object["foreground_palette_index"] = style.foregroundPaletteIndex
            object["background_source"] = style.backgroundSource?.rawValue
            object["background_palette_index"] = style.backgroundPaletteIndex
            return object
        }
        var object: [String: Any] = [
            "format": frame.format, "surface_id": frame.surfaceID, "state_seq": frame.stateSeq,
            "applied_input_sequence": frame.appliedInputSequence ?? 0,
            "render_epoch": frame.renderEpoch, "render_revision": frame.renderRevision,
            "columns": frame.columns, "rows": frame.rows, "full": frame.full,
            "cleared_rows": frame.clearedRows,
            "styles": fullStyles.map(style),
            "row_spans": frame.rowSpans.map { span in
                ["row": span.row, "column": span.column, "style_id": span.styleID, "text": span.text] as [String: Any]
            },
            "active_screen": frame.activeScreen.rawValue,
            "modes": frame.modes.map { ["code": $0.code, "ansi": $0.ansi, "on": $0.on] as [String: Any] },
            "scrollback_rows": frame.scrollbackRows, "scrollback_spans": [Any](),
            "anchor": frame.anchor.rawValue, "scrolled_rows": frame.scrolledRows,
        ]
        if let cursor = frame.cursor {
            object["cursor"] = [
                "row": cursor.row, "column": cursor.column, "visible": cursor.visible,
                "style": cursor.style.rawValue, "blinking": cursor.blinking,
            ] as [String: Any]
        }
        object["history_rows"] = frame.historyRows
        object["delta_base_history_rows"] = frame.deltaBaseHistoryRows
        object["delta_base_render_revision"] = frame.deltaBaseRenderRevision
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func agentSessionDeltaStream() async throws {
        var previous = try Self.screen(frame: 0)
        var deltas: [MobileTerminalRenderGridFrame] = []
        let frameCount = 600
        for index in 1...frameCount {
            let current = try Self.screen(frame: index)
            let previousRows = previous.rowSignatures()
            let currentRows = current.rowSignatures()
            let changed = Set((0..<Self.rows).filter { previousRows[$0] != currentRows[$0] })
            deltas.append(try current.filteredRows(
                changed,
                full: false,
                deltaBaseHistoryRows: previous.historyRows,
                deltaBaseRenderRevision: previous.renderRevision
            ))
            previous = current
        }

        let legacy = try deltas.map { try Self.legacyJSON($0, fullStyles: Self.styles) }
        let clock = ContinuousClock()
        var json: [Data] = []
        let jsonEncode = try clock.measure { json = try deltas.map { try JSONEncoder().encode($0) } }
        let jsonDecode = try clock.measure {
            for payload in json { _ = try MobileTerminalRenderGridFrame.decode(payload) }
        }
        var binary: [Data] = []
        let binaryEncode = try clock.measure { binary = try deltas.map { try $0.binaryEncoded() } }
        let binaryDecode = try clock.measure {
            for payload in binary { _ = try MobileTerminalRenderGridFrame.decodeBinary(payload) }
        }

        func laneBytes(_ payloads: [Data]) async throws -> (raw: Int, deflated: Int) {
            let sink = RecordingSink()
            let lane = try IrxEncodingLaneWriter(sink, encoding: .deflate)
            var raw = 0
            for payload in payloads {
                let frame = try MobileSyncFrameCodec.encodeFrame(payload)
                raw += frame.count
                try await lane.write(frame)
            }
            return (raw, await sink.total)
        }
        let legacyBytes = try await laneBytes(legacy)
        let jsonBytes = try await laneBytes(json)
        let binaryBytes = try await laneBytes(binary)
        func perFrame(_ bytes: Int) -> Int { bytes / frameCount }
        func microsPerFrame(_ duration: Duration) -> Int {
            Int(duration / .microseconds(1)) / frameCount
        }
        print(
            "render-grid wire benchmark (\(frameCount) deltas, 120x40, 37 styles) B/frame: " +
                "legacy=\(perFrame(legacyBytes.raw)) legacy+deflate=\(perFrame(legacyBytes.deflated)) " +
                "json=\(perFrame(jsonBytes.raw)) json+deflate=\(perFrame(jsonBytes.deflated)) " +
                "binary=\(perFrame(binaryBytes.raw)) binary+deflate=\(perFrame(binaryBytes.deflated)); " +
                "µs/frame: json encode=\(microsPerFrame(jsonEncode)) decode=\(microsPerFrame(jsonDecode)) " +
                "binary encode=\(microsPerFrame(binaryEncode)) decode=\(microsPerFrame(binaryDecode))"
        )
        #expect(binaryBytes.raw * 2 < jsonBytes.raw)
        #expect(binaryBytes.deflated < jsonBytes.deflated)
        #expect(jsonBytes.deflated * 10 < legacyBytes.raw)
    }
}

private actor RecordingSink: IrxEventLaneWriting {
    private(set) var total = 0
    func write(_ data: Data) async throws { total += data.count }
    func setPriority(_: Int32) async throws {}
    func finish() async {}
    func reset(errorCode _: UInt64) async {}
}
