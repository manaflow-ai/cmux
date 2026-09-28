import Foundation
import Testing
@testable import CMUXMobileCore

private func richFrame() throws -> MobileTerminalRenderGridFrame {
    var frame = try MobileTerminalRenderGridFrame(
        surfaceID: "8C0A57A4-7F1B-4D0B-9C39-2F4E8B1A6D10",
        stateSeq: 90_210,
        appliedInputSequence: 0,
        renderEpoch: "3E7C1D2A-55B0-4C8F-A1D2-9B7E6F5A4C3B",
        renderRevision: 1 << 40,
        columns: 120,
        rows: 3,
        cursor: .init(row: 2, column: 7, visible: false, style: .blockHollow, blinking: true),
        full: true,
        styles: [
            .init(id: 0, foreground: "#D8D8D8", background: "#1e1e1e"),
            .init(
                id: 9,
                foreground: "#Ab12Cd",
                background: "rgb:ff/00/00",
                foregroundSource: .palette,
                foregroundPaletteIndex: 255,
                backgroundSource: .rgb,
                bold: true,
                inverse: true,
                overline: true
            ),
            .init(id: 300, backgroundSource: .defaultColor, faint: true, strikethrough: true),
        ],
        rowSpans: [
            .init(row: 0, column: 0, styleID: 9, text: "héllo 🌍 wörld"),
            .init(row: 1, column: 4, styleID: 300, text: "界", cellWidth: 2),
            .init(row: 2, column: 0, styleID: 0, text: "x"),
        ],
        activeScreen: .alternate,
        modes: [.init(code: 2004, on: true), .init(code: 4, ansi: true, on: false)],
        terminalForeground: "#FFFFFF",
        terminalBackground: "#000000",
        terminalCursorColor: nil,
        terminalTheme: .monokai,
        terminalConfigTheme: .monokai,
        terminalThemeRevision: 12,
        scrollbackRows: 2,
        scrollbackSpans: [.init(row: 1, column: 0, styleID: 0, text: "history")],
        anchor: .screen,
        historyRows: 0,
        rowSpaceRevision: 5
    )
    frame.hostTiming = MobileTerminalHostTiming(inputReceivedMicros: 1, frameCapturedMicros: 3)
    return frame
}

@Test func binaryRenderGridRoundTripsFullAndDeltaFramesExactly() throws {
    let full = try richFrame()
    let delta = try full.filteredRows([0, 2], full: false, deltaBaseHistoryRows: 7, deltaBaseRenderRevision: 8)
    let plain = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "live-terminal", stateSeq: 0, columns: 4, rows: 2, text: "ab\n", full: false, changedRows: [0]
    )
    for frame in [full, delta, plain] {
        let encoded = try frame.binaryEncoded()
        #expect(MobileTerminalRenderGridFrame.isBinaryFrame(encoded))
        #expect(try MobileTerminalRenderGridFrame.decodeBinary(encoded) == frame)
    }
}

@Test func binaryRenderGridRejectsEveryTruncationAndForeignBytes() throws {
    let encoded = try richFrame().binaryEncoded()
    for length in 0..<encoded.count {
        #expect(throws: (any Error).self) {
            try MobileTerminalRenderGridFrame.decodeBinary(encoded.prefix(length))
        }
    }
    var trailing = encoded
    trailing.append(0)
    #expect(throws: (any Error).self) { try MobileTerminalRenderGridFrame.decodeBinary(trailing) }
    var newerVersion = encoded
    newerVersion[newerVersion.startIndex + 1] = MobileTerminalRenderGridFrame.binaryFormatVersion + 1
    #expect(throws: MobileTerminalRenderGridFrame.BinaryDecodingError.unsupportedVersion(
        MobileTerminalRenderGridFrame.binaryFormatVersion + 1
    )) { try MobileTerminalRenderGridFrame.decodeBinary(newerVersion) }
    #expect(!MobileTerminalRenderGridFrame.isBinaryFrame(Data(#"{"kind":"event"}"#.utf8)))
}

@Test func binaryRenderGridSurvivesRandomCorruptionWithoutCrashing() throws {
    let encoded = Array(try richFrame().binaryEncoded())
    var state: UInt64 = 0x2545_F491_4F6C_DD1D
    for _ in 0..<2_000 {
        var bytes = encoded
        for _ in 0..<3 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let index = 2 + Int(state % UInt64(bytes.count - 2))
            bytes[index] = UInt8(truncatingIfNeeded: state >> 32)
        }
        // Either a validated frame or an error; never a trap or a hang.
        _ = try? MobileTerminalRenderGridFrame.decodeBinary(Data(bytes))
    }
}
