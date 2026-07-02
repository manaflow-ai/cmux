import Foundation
import Testing
@testable import CMUXMobileCore

@Test func renderGridFullSnapshotRestoresAlternateScreenAndModes() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 1,
        columns: 8,
        rows: 2,
        cursor: .init(row: 0, column: 0),
        rowSpans: [.init(row: 0, column: 0, text: "TUI")],
        activeScreen: .alternate,
        modes: [
            .init(code: 1000, ansi: false, on: true), // mouse tracking (DEC private)
            .init(code: 2004, ansi: false, on: true), // bracketed paste (DEC private)
            .init(code: 4, ansi: true, on: true),     // insert mode (ANSI, no `?`)
            .init(code: 3, ansi: false, on: true),    // DECCOLM: geometry handled separately
            .init(code: 1049, ansi: false, on: true), // alt-screen: handled separately
        ]
    )

    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    #expect(vt.hasPrefix("\u{1B}[?2026h\u{1B}[0$}"))
    #expect(vt.hasSuffix("\u{1B}[?2026l"))
    #expect(vt.contains("\u{1B}[?1049h")) // entered the alternate screen
    #expect(vt.contains("\u{1B}[?1000h")) // mouse mode restored
    #expect(vt.contains("\u{1B}[?2004h")) // bracketed paste restored
    #expect(vt.contains("\u{1B}[4h"))     // ANSI insert mode restored without `?`
    #expect(vt.contains("\u{1B}[?1049l")) // left alternate before clearing primary scrollback
    #expect(!vt.contains("\u{1B}[?3h"))   // DECCOLM would resize away from the remote grid
    // The alt-screen mode in `modes` is ignored; the two `?1049h` emissions are
    // the synchronized reset prelude and the captured active screen.
    #expect(vt.components(separatedBy: "\u{1B}[?1049h").count - 1 == 2)
}

@Test func renderGridFullSnapshotDefaultsOmittedModeListBeforeCursorRestore() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 1,
        columns: 8,
        rows: 1,
        cursor: .init(row: 0, column: 6),
        rowSpans: [.init(row: 0, column: 0, text: "legacy")]
    )

    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    let content = try #require(vt.range(of: "legacy"))
    let postPaintRange = content.upperBound..<vt.endIndex

    #expect(vt.range(of: "\u{1B}[?1l", range: postPaintRange) != nil)
    #expect(vt.range(of: "\u{1B}[4l", range: postPaintRange) != nil)
    #expect(vt.range(of: "\u{1B}[?6l", range: postPaintRange) != nil)
    #expect(vt.range(of: "\u{1B}[?7h", range: postPaintRange) != nil)
    #expect(vt.range(of: "\u{1B}[?1000l", range: postPaintRange) != nil)
    #expect(vt.range(of: "\u{1B}[?1006l", range: postPaintRange) != nil)
    #expect(vt.range(of: "\u{1B}[?2004l", range: postPaintRange) != nil)
    #expect(vt.range(of: "\u{1B}[?2027l", range: postPaintRange) != nil)
    #expect(vt.range(of: "\u{1B}[?2031l", range: postPaintRange) != nil)
    #expect(vt.range(of: "\u{1B}[?2048l", range: postPaintRange) != nil)
    #expect(vt.range(of: "\u{1B}>", range: postPaintRange) != nil)
}

@Test func renderGridFullSnapshotReappliesCapturedModesAfterDefaultBaseline() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 1,
        columns: 8,
        rows: 1,
        cursor: .init(row: 0, column: 4),
        rowSpans: [.init(row: 0, column: 0, text: "mode")],
        modes: [
            .init(code: 1, ansi: false, on: true),
            .init(code: 4, ansi: true, on: true),
            .init(code: 1000, ansi: false, on: true),
            .init(code: 2004, ansi: false, on: true),
            .init(code: 2027, ansi: false, on: true),
        ]
    )

    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    let content = try #require(vt.range(of: "mode"))
    let graphemeRestore = try #require(vt.range(of: "\u{1B}[?2027h"))
    let appCursorReset = try #require(vt.range(of: "\u{1B}[?1l", range: content.upperBound..<vt.endIndex))
    let appCursorRestore = try #require(vt.range(of: "\u{1B}[?1h", range: appCursorReset.upperBound..<vt.endIndex))
    let insertReset = try #require(vt.range(of: "\u{1B}[4l", range: content.upperBound..<vt.endIndex))
    let insertRestore = try #require(vt.range(of: "\u{1B}[4h", range: insertReset.upperBound..<vt.endIndex))
    let mouseReset = try #require(vt.range(of: "\u{1B}[?1000l", range: content.upperBound..<vt.endIndex))
    let mouseRestore = try #require(vt.range(of: "\u{1B}[?1000h", range: mouseReset.upperBound..<vt.endIndex))
    let pasteReset = try #require(vt.range(of: "\u{1B}[?2004l", range: content.upperBound..<vt.endIndex))
    let pasteRestore = try #require(vt.range(of: "\u{1B}[?2004h", range: pasteReset.upperBound..<vt.endIndex))

    #expect(graphemeRestore.lowerBound < content.lowerBound)
    #expect(appCursorReset.lowerBound < appCursorRestore.lowerBound)
    #expect(insertReset.lowerBound < insertRestore.lowerBound)
    #expect(mouseReset.lowerBound < mouseRestore.lowerBound)
    #expect(pasteReset.lowerBound < pasteRestore.lowerBound)
}

@Test func renderGridFullSnapshotResetsSemanticPromptStateOnBothScreensBeforePaint() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 7,
        columns: 8,
        rows: 1,
        cursor: .init(row: 0, column: 4),
        rowSpans: [.init(row: 0, column: 0, text: "cell")]
    )

    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    let content = try #require(vt.range(of: "cell"))
    let semanticReset = "\u{1B}]133;D\u{1B}\\"
    // One reset per screen: the cursor's OSC 133 semantic content is
    // per-screen state, and RIS (which used to clear it) is no longer sent.
    let primaryReset = try #require(vt.range(of: semanticReset))
    let alternateReset = try #require(
        vt.range(of: semanticReset, range: primaryReset.upperBound..<vt.endIndex)
    )
    #expect(alternateReset.upperBound <= content.lowerBound)
}

@Test func renderGridFullSnapshotOverwritesSavedModeBankAtDefaults() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 8,
        columns: 8,
        rows: 1,
        cursor: .init(row: 0, column: 4),
        rowSpans: [.init(row: 0, column: 0, text: "bank")],
        modes: [
            .init(code: 2004, ansi: false, on: true),
        ]
    )

    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    let content = try #require(vt.range(of: "bank"))
    // XTSAVE must snapshot the saved-mode bank while every listed mode still
    // holds its default (before the frame's captured modes are reapplied and
    // before content paints), replacing the saved-bank clear RIS used to do.
    let firstBatch = try #require(vt.range(of: "\u{1B}[?1;4;5;6;7;8;9;40;45;47;66;67;69;1000;1002;1003s"))
    let secondBatch = try #require(vt.range(
        of: "\u{1B}[?1004;1005;1006;1007;1015;1016;1035;1036;1039;1045;1047;1049;2004;2027;2031;2048s"
    ))
    let capturedPasteRestore = try #require(vt.range(of: "\u{1B}[?2004h"))
    #expect(firstBatch.upperBound <= secondBatch.lowerBound)
    #expect(secondBatch.upperBound <= content.lowerBound)
    #expect(secondBatch.upperBound <= capturedPasteRestore.lowerBound)
    // The bank is written once, before paint; the post-paint baseline must not
    // re-save state that no longer holds defaults.
    #expect(vt.components(separatedBy: "\u{1B}[?1;4;5;6;7;8;9;40;45;47;66;67;69;1000;1002;1003s").count - 1 == 1)
}

@Test func renderGridFullSnapshotResetsPrimaryCursorShapeBeforeAlternateEntry() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 9,
        columns: 8,
        rows: 1,
        cursor: .init(row: 0, column: 0, style: .bar, blinking: false),
        rowSpans: [.init(row: 0, column: 0, text: "TUI")],
        activeScreen: .alternate
    )

    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    // Cursor shape is per-screen state that survives the ?1049 roundtrip, so
    // the primary screen must be reset to the default shape before the replay
    // enters the alternate screen; otherwise a stale bar/underline shape from
    // the reused surface reappears when the TUI exits.
    let shapeReset = try #require(vt.range(of: "\u{1B}[0 q"))
    let alternateEntry = try #require(vt.range(of: "\u{1B}[?1049h"))
    #expect(shapeReset.upperBound <= alternateEntry.lowerBound)
    // The frame's captured cursor shape still lands last on the active screen.
    let capturedShape = try #require(vt.range(of: "\u{1B}[6 q"))
    #expect(alternateEntry.upperBound <= capturedShape.lowerBound)
}
