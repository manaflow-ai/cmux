import Foundation
import Testing
@testable import CMUXMobileCore

@Test func renderGridFrameEncodesVisibleRowsAndCursor() throws {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a",
        stateSeq: 42,
        columns: 8,
        rows: 4,
        text: "alpha   \n\n beta\n",
        cursor: .init(row: 2, column: 5)
    )

    #expect(frame.rowSpans == [
        .init(row: 0, column: 0, text: "alpha"),
        .init(row: 2, column: 0, text: " beta"),
    ])

    let decoded = try MobileTerminalRenderGridFrame.decodeJSONObject(frame.jsonObject())
    #expect(decoded == frame)
    // A full snapshot is restored as a synchronized, autowrap-off scrolling
    // flow: reset, paint each viewport row (CHA-positioned spans), then restore
    // the cursor.
    #expect(String(data: frame.vtReplacementBytes(), encoding: .utf8) ==
        "\u{1B}c\u{1B}[?2026h" +
        "\u{1B}[?7l\u{1B}[?25l\u{1B}[0m" +
        "\u{1B}[0m\u{1B}[1Galpha" +
        "\r\n\u{1B}[0m" +
        "\r\n\u{1B}[0m\u{1B}[1G beta" +
        "\r\n\u{1B}[0m" +
        "\u{1B}[0m\u{1B}[2 q\u{1B}[?25h\u{1B}[3;6H" +
        "\u{1B}[?2026l"
    )
}

@Test func renderGridDeltaClearsOnlyChangedRows() throws {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a",
        stateSeq: 43,
        columns: 8,
        rows: 4,
        text: "alpha\nchanged\n\nomega",
        full: false,
        changedRows: [1, 2]
    )

    #expect(frame.full == false)
    #expect(frame.clearedRows == [1, 2])
    #expect(frame.rowSpans == [
        .init(row: 1, column: 0, text: "changed"),
    ])
    #expect(String(data: frame.vtPatchBytes(), encoding: .utf8) ==
        "\u{1B}[0m\u{1B}[2;1H\u{1B}[2K" +
        "\u{1B}[0m\u{1B}[3;1H\u{1B}[2K" +
        "\u{1B}[2;1H\u{1B}[0mchanged" +
        "\u{1B}[0m"
    )
}

@Test func renderGridDeltaClearsShortenedRowForBackspace() throws {
    // A held backspace shortens the prompt line ("echo hello" -> "echo hell").
    // The delta must erase the whole row (ESC[2K) before repainting so the
    // deleted trailing cell is cleared, not left stale. This is the consumer
    // half of the held-backspace render path.
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a",
        stateSeq: 44,
        columns: 12,
        rows: 1,
        text: "echo hell",
        full: false,
        changedRows: [0]
    )

    #expect(frame.full == false)
    #expect(frame.clearedRows == [0])
    #expect(frame.rowSpans == [
        .init(row: 0, column: 0, text: "echo hell"),
    ])
    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    // Erase the row, then repaint the shortened text.
    #expect(vt.contains("\u{1B}[1;1H\u{1B}[2K"))
    #expect(vt.contains("echo hell"))
}

@Test func renderGridDeltaClearsRowEmptiedByBackspace() throws {
    // Deleting an entire line leaves a row with no spans at all. The delta must
    // still emit ESC[2K for that row so stale content does not survive on the
    // consumer when there is nothing to repaint.
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a",
        stateSeq: 45,
        columns: 12,
        rows: 1,
        text: "",
        full: false,
        changedRows: [0]
    )

    #expect(frame.clearedRows == [0])
    #expect(frame.rowSpans.isEmpty)
    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    #expect(vt.contains("\u{1B}[1;1H\u{1B}[2K"))
}

@Test func renderGridPatchPreservesRgbStylesAndCursorShape() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 45,
        columns: 8,
        rows: 4,
        cursor: .init(row: 1, column: 2, style: .bar, blinking: false),
        styles: [
            .init(id: 0, foreground: "#C0C0C0", background: "#101010"),
            .init(
                id: 1,
                foreground: "#FF0000",
                background: "#0000FF",
                bold: true,
                underline: true
            ),
        ],
        rowSpans: [
            .init(row: 0, column: 0, styleID: 1, text: "red"),
        ]
    )

    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    #expect(vt.contains("\u{1B}[0;38;2;192;192;192;48;2;16;16;16m"))
    #expect(vt.contains("\u{1B}[0;1;4;38;2;255;0;0;48;2;0;0;255mred"))
    #expect(vt.contains("\u{1B}[6 q\u{1B}[?25h\u{1B}[2;3H"))
}

@Test func renderGridFilteredRowsKeepStyledSpans() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 46,
        columns: 8,
        rows: 4,
        styles: [
            .init(id: 0, foreground: "#FFFFFF", background: "#000000"),
            .init(id: 1, foreground: "#00FF00", background: "#000000"),
        ],
        rowSpans: [
            .init(row: 0, column: 0, text: "same"),
            .init(row: 1, column: 0, styleID: 1, text: "green"),
        ]
    )

    let delta = try frame.filteredRows([1], full: false)

    #expect(delta.full == false)
    #expect(delta.clearedRows == [1])
    #expect(delta.styles == frame.styles)
    #expect(delta.rowSpans == [.init(row: 1, column: 0, styleID: 1, text: "green")])
    #expect(try #require(String(data: delta.vtPatchBytes(), encoding: .utf8))
        .contains("\u{1B}[0;38;2;0;255;0;48;2;0;0;0mgreen"))
}

@Test func renderGridSpanCellWidthSupportsWideCells() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 47,
        columns: 2,
        rows: 1,
        rowSpans: [
            .init(row: 0, column: 0, text: "界", cellWidth: 2),
        ]
    )

    #expect(frame.plainRows() == ["界 "])
}

@Test func renderGridDecodesReplayFramesFromPreviousShape() throws {
    let object: [String: Any] = [
        "format": MobileTerminalRenderGridFrame.currentFormat,
        "surface_id": "terminal-a",
        "state_seq": NSNumber(value: 44),
        "columns": 8,
        "rows": 4,
        "styles": [["id": 0]],
        "row_spans": [
            ["row": 0, "column": 0, "style_id": 0, "text": "alpha"],
        ],
    ]

    let frame = try MobileTerminalRenderGridFrame.decodeJSONObject(object)

    #expect(frame.full)
    #expect(frame.clearedRows.isEmpty)
    #expect(frame.rowSpans == [.init(row: 0, column: 0, text: "alpha")])
}

@Test func renderGridRejectsInvalidSpanCoordinates() throws {
    #expect(throws: MobileTerminalRenderGridError.invalidColumn(9)) {
        _ = try MobileTerminalRenderGridFrame(
            surfaceID: "terminal-a",
            stateSeq: 1,
            columns: 8,
            rows: 4,
            rowSpans: [
                .init(row: 0, column: 9, text: "overflow"),
            ]
        )
    }
}

@Test func renderGridRowSignaturesDetectStyleOnlyChanges() throws {
    // Same text, but the cell flips from a dimmed (faint) autosuggestion style
    // to the normal style — as when a character is typed over a zsh suggestion.
    // plainRows() is identical, so a text-only diff would miss it; the signature
    // must differ so the row is re-sent.
    let dim = try MobileTerminalRenderGridFrame(
        surfaceID: "t",
        stateSeq: 1,
        columns: 8,
        rows: 1,
        styles: [.default, .init(id: 1, faint: true)],
        rowSpans: [.init(row: 0, column: 0, styleID: 1, text: "ls")]
    )
    let normal = try MobileTerminalRenderGridFrame(
        surfaceID: "t",
        stateSeq: 2,
        columns: 8,
        rows: 1,
        styles: [.default],
        rowSpans: [.init(row: 0, column: 0, styleID: 0, text: "ls")]
    )

    #expect(dim.plainRows() == normal.plainRows()) // text-only diff would miss it
    #expect(dim.rowSignatures() != normal.rowSignatures())
    #expect(dim.rowSignatures() == dim.rowSignatures()) // stable

    // Identical content (different per-frame style ids, same resolved style)
    // produces an identical signature, so unchanged rows are not re-sent.
    let sameA = try MobileTerminalRenderGridFrame(
        surfaceID: "t", stateSeq: 3, columns: 8, rows: 1,
        styles: [.init(id: 0, foreground: "#FF0000")],
        rowSpans: [.init(row: 0, column: 0, styleID: 0, text: "hi")]
    )
    let sameB = try MobileTerminalRenderGridFrame(
        surfaceID: "t", stateSeq: 4, columns: 8, rows: 1,
        styles: [.default, .init(id: 1, foreground: "#FF0000")],
        rowSpans: [.init(row: 0, column: 0, styleID: 1, text: "hi")]
    )
    #expect(sameA.rowSignatures() == sameB.rowSignatures())
}

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
            .init(code: 1049, ansi: false, on: true), // alt-screen: handled separately
        ]
    )

    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    #expect(vt.hasPrefix("\u{1B}c\u{1B}[?2026h"))
    #expect(vt.hasSuffix("\u{1B}[?2026l"))
    #expect(vt.contains("\u{1B}[?1049h")) // entered the alternate screen
    #expect(vt.contains("\u{1B}[?1000h")) // mouse mode restored
    #expect(vt.contains("\u{1B}[?2004h")) // bracketed paste restored
    #expect(vt.contains("\u{1B}[4h"))     // ANSI insert mode restored without `?`
    #expect(!vt.contains("\u{1B}[?1049l"))
    // The alt-screen mode in `modes` is ignored; the only `?1049h` is the one
    // emitted from `activeScreen`.
    #expect(vt.components(separatedBy: "\u{1B}[?1049h").count - 1 == 1)
}

@Test func renderGridFullSnapshotFlowsScrollbackBeforeViewport() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 1,
        columns: 8,
        rows: 2,
        cursor: .init(row: 1, column: 0),
        rowSpans: [
            .init(row: 0, column: 0, text: "vp0"),
            .init(row: 1, column: 0, text: "vp1"),
        ],
        scrollbackRows: 2,
        scrollbackSpans: [
            .init(row: 0, column: 0, text: "old0"),
            .init(row: 1, column: 0, text: "old1"),
        ]
    )

    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    let old0 = try #require(vt.range(of: "old0"))
    let old1 = try #require(vt.range(of: "old1"))
    let vp0 = try #require(vt.range(of: "vp0"))
    let vp1 = try #require(vt.range(of: "vp1"))
    #expect(old0.lowerBound < old1.lowerBound)
    #expect(old1.lowerBound < vp0.lowerBound)
    #expect(vp0.lowerBound < vp1.lowerBound)
    // 2 scrollback + 2 viewport rows flow as one continuous block (3 CRLFs).
    #expect(vt.components(separatedBy: "\r\n").count - 1 == 3)
}

@Test func renderGridFullSnapshotRestoresDynamicColors() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 1,
        columns: 4,
        rows: 1,
        rowSpans: [],
        terminalForeground: "#AABBCC",
        terminalBackground: "#102030",
        terminalCursorColor: "#FFEEDD"
    )

    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    #expect(vt.contains("\u{1B}]10;rgb:aa/bb/cc\u{1B}\\"))
    #expect(vt.contains("\u{1B}]11;rgb:10/20/30\u{1B}\\"))
    #expect(vt.contains("\u{1B}]12;rgb:ff/ee/dd\u{1B}\\"))
}

@Test func renderGridEncodesFullStateFields() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 7,
        columns: 8,
        rows: 2,
        rowSpans: [.init(row: 0, column: 0, text: "hi")],
        activeScreen: .alternate,
        modes: [
            .init(code: 1, ansi: false, on: true),
            .init(code: 20, ansi: true, on: false),
        ],
        terminalForeground: "#010203",
        scrollbackRows: 1,
        scrollbackSpans: [.init(row: 0, column: 0, text: "sb")]
    )

    let decoded = try MobileTerminalRenderGridFrame.decodeJSONObject(frame.jsonObject())
    #expect(decoded == frame)
    #expect(decoded.activeScreen == .alternate)
    #expect(decoded.modes == [
        .init(code: 1, ansi: false, on: true),
        .init(code: 20, ansi: true, on: false),
    ])
    #expect(decoded.scrollbackRows == 1)
    #expect(decoded.scrollbackSpans == [.init(row: 0, column: 0, text: "sb")])
    #expect(decoded.terminalForeground == "#010203")
}

@Test func renderGridDeltaDropsFullStateFields() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 1,
        columns: 8,
        rows: 4,
        full: false,
        styles: [.default],
        rowSpans: [.init(row: 1, column: 0, text: "x")],
        activeScreen: .alternate,
        modes: [.init(code: 1000, ansi: false, on: true)],
        scrollbackRows: 3,
        scrollbackSpans: [.init(row: 0, column: 0, text: "sb")]
    )

    // A delta frame carries no scrollback and does not enter the alt screen or
    // replay modes; it only clears and repaints its changed rows.
    #expect(frame.scrollbackRows == 0)
    #expect(frame.scrollbackSpans.isEmpty)
    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    #expect(!vt.contains("\u{1B}c"))
    #expect(!vt.contains("\u{1B}[?1049h"))
    #expect(!vt.contains("\u{1B}[?1000h"))
}

@Test func replaySynthesizerMatchesFrameForwardersAcrossFrameShapes() throws {
    // Full primary-screen snapshot with scrollback, styles, and a cursor.
    let fullFrame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 100,
        columns: 8,
        rows: 3,
        cursor: .init(row: 1, column: 2, style: .bar, blinking: true),
        full: true,
        styles: [
            .init(id: 0, foreground: "#C0C0C0", background: "#101010"),
            .init(id: 1, foreground: "#FF0000", bold: true),
        ],
        rowSpans: [
            .init(row: 0, column: 0, styleID: 1, text: "hi"),
            .init(row: 2, column: 1, styleID: 0, text: "bye"),
        ],
        terminalForeground: "#FFFFFF",
        scrollbackRows: 1,
        scrollbackSpans: [.init(row: 0, column: 0, styleID: 1, text: "past")]
    )
    // Delta frame painting only changed rows.
    let deltaFrame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 101,
        columns: 8,
        rows: 3,
        full: false,
        rowSpans: [.init(row: 1, column: 0, text: "delta")]
    )

    for frame in [fullFrame, deltaFrame] {
        let replay = MobileTerminalRenderGridReplay(frame)
        #expect(replay.patchBytes() == frame.vtPatchBytes())
        #expect(replay.replacementBytes() == frame.vtReplacementBytes())
        #expect(replay.patchBytes() == replay.replacementBytes())
    }
}
