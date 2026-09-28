import Foundation
import Testing
@testable import CMUXMobileCore

/// Per-capture Mac cost after Ghostty hands over a binary frame: decode it,
/// compare it with the previous capture, and encode the delta. Prints
/// microseconds per stage; run with `-c release` for meaningful numbers.
@Test func capturePipelineStageCosts() throws {
    func screen(_ index: Int) throws -> MobileTerminalRenderGridFrame {
        let styles = [MobileTerminalRenderGridFrame.Style(id: 0, foreground: "#D8D8D8", background: "#1E1E1E")]
            + (1...36).map { id in
                MobileTerminalRenderGridFrame.Style(
                    id: id,
                    foreground: String(format: "#%02X%02X%02X", id * 7 % 256, id * 13 % 256, id * 29 % 256),
                    foregroundSource: .palette,
                    foregroundPaletteIndex: id % 16,
                    bold: id.isMultiple(of: 3)
                )
            }
        var spans: [MobileTerminalRenderGridFrame.RowSpan] = []
        for row in 0..<40 {
            var column = 0
            for part in 0..<8 where column < 110 {
                let text = "w\(row)-\(part)-\(row == 39 ? index : 0)"
                spans.append(.init(row: row, column: column, styleID: (row + part) % 36 + 1, text: text))
                column += text.count + 1
            }
        }
        return try MobileTerminalRenderGridFrame(
            surfaceID: "8C0A57A4-7F1B-4D0B-9C39-2F4E8B1A6D10", stateSeq: UInt64(index),
            renderEpoch: "e", renderRevision: UInt64(index + 1), columns: 120, rows: 40,
            cursor: .init(row: 39, column: 2), styles: styles, rowSpans: spans,
            modes: [.init(code: 7, on: true)], anchor: .screen, historyRows: 100, rowSpaceRevision: 1
        )
    }
    let iterations = 300
    let captures = try (0...iterations).map { try screen($0).binaryEncoded() }
    let clock = ContinuousClock()
    var decoded: [MobileTerminalRenderGridFrame] = []
    let decode = try clock.measure { decoded = try captures.map(MobileTerminalRenderGridFrame.decodeBinary) }
    let signatures = clock.measure { for frame in decoded { _ = frame.rowSignatures() } }
    var previous: MobileTerminalRenderGridEmissionState?
    var deltas: [MobileTerminalRenderGridFrame] = []
    let emission = try clock.measure {
        for frame in decoded {
            if case .emit(let delta, let state) = try frame.renderGridEmission(comparedTo: previous) {
                deltas.append(delta)
                previous = state
            }
        }
    }
    let encode = try clock.measure { for delta in deltas { _ = try delta.binaryEncoded() } }
    func perCapture(_ duration: Duration) -> Int { Int(duration / .microseconds(1)) / (iterations + 1) }
    print(
        "capture pipeline µs/capture (120x40, 37 styles): decode=\(perCapture(decode)) " +
            "rowSignatures=\(perCapture(signatures)) emission=\(perCapture(emission)) " +
            "deltaEncode=\(perCapture(encode)) captureBytes=\(captures[1].count)"
    )
    #expect(deltas.count == iterations + 1)
}
