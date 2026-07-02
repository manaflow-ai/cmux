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
        ]
    )

    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    let content = try #require(vt.range(of: "mode"))
    let appCursorReset = try #require(vt.range(of: "\u{1B}[?1l", range: content.upperBound..<vt.endIndex))
    let appCursorRestore = try #require(vt.range(of: "\u{1B}[?1h", range: appCursorReset.upperBound..<vt.endIndex))
    let insertReset = try #require(vt.range(of: "\u{1B}[4l", range: content.upperBound..<vt.endIndex))
    let insertRestore = try #require(vt.range(of: "\u{1B}[4h", range: insertReset.upperBound..<vt.endIndex))
    let mouseReset = try #require(vt.range(of: "\u{1B}[?1000l", range: content.upperBound..<vt.endIndex))
    let mouseRestore = try #require(vt.range(of: "\u{1B}[?1000h", range: mouseReset.upperBound..<vt.endIndex))
    let pasteReset = try #require(vt.range(of: "\u{1B}[?2004l", range: content.upperBound..<vt.endIndex))
    let pasteRestore = try #require(vt.range(of: "\u{1B}[?2004h", range: pasteReset.upperBound..<vt.endIndex))

    #expect(appCursorReset.lowerBound < appCursorRestore.lowerBound)
    #expect(insertReset.lowerBound < insertRestore.lowerBound)
    #expect(mouseReset.lowerBound < mouseRestore.lowerBound)
    #expect(pasteReset.lowerBound < pasteRestore.lowerBound)
}
