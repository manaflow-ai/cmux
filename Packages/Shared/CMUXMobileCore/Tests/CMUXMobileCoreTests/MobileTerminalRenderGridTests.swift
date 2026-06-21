import Foundation
import Testing
@testable import CMUXMobileCore

@Test func mobileScrollbackBudgetsKeepReplayAndMirrorCapacityCoupled() {
    let budget = MobileTerminalScrollbackBudget.localMirror
    let scxLiveTailPhysicalRows = 2_600
    let scxWrapScrollPhysicalRows = 2_600 * 3
    let visibleRows: UInt64 = 48

    #expect(MobileTerminalScrollbackBudget.fullReplayRows == budget.fullReplayRows)
    #expect(MobileTerminalScrollbackBudget.localMirrorScrollbackLimitBytes == budget.localMirrorScrollbackLimitBytes)
    #expect(budget.fullReplayRows >= scxLiveTailPhysicalRows)
    #expect(budget.fullReplayRows >= scxWrapScrollPhysicalRows)
    #expect(budget.expectedTotalRows(scrollbackRows: scxWrapScrollPhysicalRows, visibleRows: visibleRows) ==
        UInt64(scxWrapScrollPhysicalRows) + visibleRows)
    #expect(budget.localMirrorScrollbackLimitBytes >= budget.fullReplayRows * 12 * 1024)
    #expect(budget.retentionAccountingSlackRows == 1)
}

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
        "\u{1B}]110\u{1B}\\\u{1B}]111\u{1B}\\\u{1B}]112\u{1B}\\" +
        "\u{1B}[?7l\u{1B}[?25l\u{1B}[0m" +
        "\u{1B}[0m\u{1B}[1Galpha" +
        "\r\n\u{1B}[0m" +
        "\r\n\u{1B}[0m\u{1B}[1G beta" +
        "\r\n\u{1B}[0m" +
        "\u{1B}[0m\u{1B}[2 q\u{1B}[?25h\u{1B}[3;6H" +
        "\u{1B}[?2026l"
    )
}

@Test func renderGridSnapshotKeepsScrollbackAndStylesSemantic() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 1,
        columns: 12,
        rows: 2,
        styles: [
            .init(id: 0, foreground: "#C0C0C0", background: "#101010"),
            .init(id: 1, foreground: "#FF0000", bold: true),
        ],
        rowSpans: [
            .init(row: 0, column: 0, styleID: 1, text: "visible"),
        ],
        terminalForeground: "#C0C0C0",
        terminalBackground: "#101010",
        scrollbackRows: 2,
        scrollbackSpans: [
            .init(row: 0, column: 0, styleID: 0, text: "old-0"),
            .init(row: 1, column: 0, styleID: 0, text: "old-1"),
        ]
    )

    let snapshot = MobileTerminalRenderGridSnapshot(frame: frame)

    #expect(snapshot.totalRows == 4)
    #expect(snapshot.visibleRowCount == 2)
    #expect(snapshot.maxRowOffset == 2)
    #expect(snapshot.visibleRows(rowOffset: 0).map(\.plainText) == ["old-0", "old-1"])
    let bottom = snapshot.visibleRows(rowOffset: snapshot.maxRowOffset)
    #expect(bottom.map(\.plainText) == ["visible", ""])
    #expect(bottom[0].spans.first?.style.foreground == "#FF0000")
    #expect(bottom[0].spans.first?.style.bold == true)
    #expect(snapshot.terminalBackground == "#101010")
}

@Test func renderGridSnapshotAppendsOverlappingLiveViewportDelta() throws {
    let full = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 1,
        columns: 20,
        rows: 3,
        rowSpans: [
            .init(row: 0, column: 0, text: "line 1"),
            .init(row: 1, column: 0, text: "line 2"),
            .init(row: 2, column: 0, text: "line 3"),
        ]
    )
    var snapshot = MobileTerminalRenderGridSnapshot(frame: full)
    let deltaFrame = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 2,
        columns: 20,
        rows: 3,
        full: false,
        clearedRows: [0, 1, 2],
        rowSpans: [
            .init(row: 0, column: 0, text: "line 2"),
            .init(row: 1, column: 0, text: "line 3"),
            .init(row: 2, column: 0, text: "line 4"),
        ]
    )
    let delta = try MobileTerminalRenderGridEnvelope.viewportDelta(deltaFrame)

    snapshot.apply(delta)

    #expect(snapshot.totalRows == 4)
    #expect(snapshot.maxRowOffset == 1)
    #expect(snapshot.visibleRows(rowOffset: snapshot.maxRowOffset).map(\.plainText) == [
        "line 2", "line 3", "line 4",
    ])
}

@Test func renderGridSnapshotShrinkViewportPreservesRowsThatBecomeScrollback() throws {
    let full = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 1,
        columns: 20,
        rows: 5,
        rowSpans: [
            .init(row: 0, column: 0, text: "line 1"),
            .init(row: 1, column: 0, text: "line 2"),
            .init(row: 2, column: 0, text: "line 3"),
            .init(row: 3, column: 0, text: "line 4"),
            .init(row: 4, column: 0, text: "line 5"),
        ]
    )
    var snapshot = MobileTerminalRenderGridSnapshot(frame: full)
    let resized = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 2,
        columns: 20,
        rows: 3,
        full: false,
        clearedRows: [0, 1, 2],
        rowSpans: [
            .init(row: 0, column: 0, text: "line 3"),
            .init(row: 1, column: 0, text: "line 4"),
            .init(row: 2, column: 0, text: "line 5"),
        ]
    )

    snapshot.apply(try MobileTerminalRenderGridEnvelope.viewportDelta(resized))

    #expect(snapshot.totalRows == 5)
    #expect(snapshot.visibleRowCount == 3)
    #expect(snapshot.visibleRows(rowOffset: 0).map(\.plainText) == ["line 1", "line 2", "line 3"])
    #expect(snapshot.visibleRows(rowOffset: snapshot.maxRowOffset).map(\.plainText) == ["line 3", "line 4", "line 5"])
}

@Test func renderGridSnapshotGrowViewportDoesNotDuplicateRevealedScrollbackRows() throws {
    let full = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 1,
        columns: 20,
        rows: 3,
        rowSpans: [
            .init(row: 0, column: 0, text: "line 3"),
            .init(row: 1, column: 0, text: "line 4"),
            .init(row: 2, column: 0, text: "line 5"),
        ],
        scrollbackRows: 2,
        scrollbackSpans: [
            .init(row: 0, column: 0, text: "line 1"),
            .init(row: 1, column: 0, text: "line 2"),
        ]
    )
    var snapshot = MobileTerminalRenderGridSnapshot(frame: full)
    let resized = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 2,
        columns: 20,
        rows: 5,
        full: false,
        clearedRows: [0, 1, 2, 3, 4],
        rowSpans: [
            .init(row: 0, column: 0, text: "line 1"),
            .init(row: 1, column: 0, text: "line 2"),
            .init(row: 2, column: 0, text: "line 3"),
            .init(row: 3, column: 0, text: "line 4"),
            .init(row: 4, column: 0, text: "line 5"),
        ]
    )

    snapshot.apply(try MobileTerminalRenderGridEnvelope.viewportDelta(resized))

    #expect(snapshot.totalRows == 5)
    #expect(snapshot.visibleRowCount == 5)
    #expect(snapshot.maxRowOffset == 0)
    #expect(snapshot.visibleRows(rowOffset: 0).map(\.plainText) == ["line 1", "line 2", "line 3", "line 4", "line 5"])
}

@Test func renderGridSnapshotPatchesPartialViewportDeltaInPlace() throws {
    let full = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 1,
        columns: 20,
        rows: 3,
        rowSpans: [
            .init(row: 0, column: 0, text: "line 1"),
            .init(row: 1, column: 0, text: "line 2"),
            .init(row: 2, column: 0, text: "line 3"),
        ]
    )
    var snapshot = MobileTerminalRenderGridSnapshot(frame: full)
    let patchFrame = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 2,
        columns: 20,
        rows: 3,
        full: false,
        clearedRows: [1],
        rowSpans: [
            .init(row: 1, column: 0, text: "patched"),
        ]
    )
    let patch = try MobileTerminalRenderGridEnvelope.viewportDelta(patchFrame)

    snapshot.apply(patch)

    #expect(snapshot.totalRows == 3)
    #expect(snapshot.visibleRows(rowOffset: 0).map(\.plainText) == [
        "line 1", "patched", "line 3",
    ])
}

@Test func renderGridSnapshotPreservesTerminalColorsWhenDeltaOmitsThem() throws {
    let full = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 1,
        columns: 20,
        rows: 2,
        rowSpans: [
            .init(row: 0, column: 0, text: "line 1"),
            .init(row: 1, column: 0, text: "line 2"),
        ],
        terminalForeground: "#E0E0E0",
        terminalBackground: "#101010",
        terminalCursorColor: "#FF00FF"
    )
    var snapshot = MobileTerminalRenderGridSnapshot(frame: full)
    let cursorOnly = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 2,
        columns: 20,
        rows: 2,
        cursor: .init(row: 1, column: 3),
        full: false,
        rowSpans: []
    )

    snapshot.apply(try MobileTerminalRenderGridEnvelope.viewportDelta(cursorOnly))

    #expect(snapshot.terminalForeground == "#E0E0E0")
    #expect(snapshot.terminalBackground == "#101010")
    #expect(snapshot.terminalCursorColor == "#FF00FF")
    #expect(snapshot.cursor?.row == 1)
    #expect(snapshot.cursor?.column == 3)
}

@Test func renderGridSnapshotResetsTerminalColorsWhenDeltaCarriesNullState() throws {
    let full = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 1,
        columns: 20,
        rows: 2,
        rowSpans: [
            .init(row: 0, column: 0, text: "line 1"),
            .init(row: 1, column: 0, text: "line 2"),
        ],
        terminalForeground: "#E0E0E0",
        terminalBackground: "#101010",
        terminalCursorColor: "#FF00FF"
    )
    var snapshot = MobileTerminalRenderGridSnapshot(frame: full)
    let reset = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 2,
        columns: 20,
        rows: 2,
        full: false,
        rowSpans: [],
        terminalForegroundIsPresent: true,
        terminalBackgroundIsPresent: true,
        terminalCursorColorIsPresent: true
    )

    snapshot.apply(try MobileTerminalRenderGridEnvelope.viewportDelta(reset))

    #expect(snapshot.terminalForeground == nil)
    #expect(snapshot.terminalBackground == nil)
    #expect(snapshot.terminalCursorColor == nil)
}

@Test func renderGridSnapshotFloorsFractionalOffsetsAndCanReturnExtraRow() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 1,
        columns: 20,
        rows: 2,
        rowSpans: [
            .init(row: 0, column: 0, text: "row 2"),
            .init(row: 1, column: 0, text: "row 3"),
        ],
        scrollbackRows: 2,
        scrollbackSpans: [
            .init(row: 0, column: 0, text: "row 0"),
            .init(row: 1, column: 0, text: "row 1"),
        ]
    )
    let snapshot = MobileTerminalRenderGridSnapshot(frame: frame)

    #expect(snapshot.fractionalRowOffset(rowOffset: 1.75) == 0.75)
    #expect(snapshot.visibleRows(rowOffset: 1.75).map(\.plainText) == ["row 1", "row 2"])
    #expect(snapshot.visibleRows(rowOffset: 1.75, extraRows: 1).map(\.plainText) == [
        "row 1", "row 2", "row 3",
    ])
}

@Test func renderGridSnapshotKeepsPrimaryScrollbackAcrossAlternateScreenDeltas() throws {
    let primary = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 1,
        columns: 20,
        rows: 2,
        rowSpans: [
            .init(row: 0, column: 0, text: "shell 1"),
            .init(row: 1, column: 0, text: "shell 2"),
        ],
        scrollbackRows: 2,
        scrollbackSpans: [
            .init(row: 0, column: 0, text: "old 1"),
            .init(row: 1, column: 0, text: "old 2"),
        ]
    )
    var snapshot = MobileTerminalRenderGridSnapshot(frame: primary)

    let alternate = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 2,
        columns: 20,
        rows: 2,
        full: false,
        clearedRows: [0, 1],
        rowSpans: [
            .init(row: 0, column: 0, text: "vim 1"),
            .init(row: 1, column: 0, text: "vim 2"),
        ],
        activeScreen: .alternate
    )
    snapshot.apply(try MobileTerminalRenderGridEnvelope.viewportDelta(alternate))
    #expect(snapshot.activeScreen == .alternate)
    #expect(snapshot.visibleRows(rowOffset: 0).map(\.plainText) == ["vim 1", "vim 2"])

    let returnedPrimary = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 3,
        columns: 20,
        rows: 2,
        full: false,
        clearedRows: [0, 1],
        rowSpans: [
            .init(row: 0, column: 0, text: "shell 3"),
            .init(row: 1, column: 0, text: "shell 4"),
        ]
    )
    snapshot.apply(try MobileTerminalRenderGridEnvelope.viewportDelta(returnedPrimary))

    #expect(snapshot.activeScreen == .primary)
    #expect(snapshot.totalRows == 4)
    #expect(snapshot.visibleRows(rowOffset: 0).map(\.plainText) == ["old 1", "old 2"])
    #expect(snapshot.visibleRows(rowOffset: snapshot.maxRowOffset).map(\.plainText) == ["shell 3", "shell 4"])
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

@Test func renderGridEnvelopeSeparatesSnapshotOwnershipFromLiveDeltas() throws {
    let snapshotFrame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 10,
        columns: 8,
        rows: 2,
        rowSpans: [
            .init(row: 0, column: 0, text: "alpha"),
            .init(row: 1, column: 0, text: "beta"),
        ],
        scrollbackRows: 1,
        scrollbackSpans: [.init(row: 0, column: 0, text: "old")]
    )
    let snapshot = try MobileTerminalRenderGridEnvelope.snapshot(snapshotFrame)

    #expect(snapshot.ownsScrollback)
    #expect(snapshot.scrollbackRowsForLocalMirror == 1)
    #expect(snapshot.replayGrid?.columns == 8)
    #expect(snapshot.replayGrid?.rows == 2)

    let deltaFrame = try snapshotFrame.filteredRows([1], full: false)
    let delta = try MobileTerminalRenderGridEnvelope.viewportDelta(deltaFrame)

    #expect(!delta.ownsScrollback)
    #expect(delta.scrollbackRowsForLocalMirror == nil)
    #expect(delta.replayGrid == nil)
}

@Test func renderGridEnvelopeRejectsAmbiguousFrameRoles() throws {
    let fullFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a",
        stateSeq: 11,
        columns: 8,
        rows: 1,
        text: "live"
    )
    let deltaFrame = try fullFrame.filteredRows([0], full: false)

    #expect(throws: MobileTerminalRenderGridEnvelope.ValidationError.viewportDeltaRequiresDeltaFrame) {
        _ = try MobileTerminalRenderGridEnvelope.viewportDelta(fullFrame)
    }
    #expect(throws: MobileTerminalRenderGridEnvelope.ValidationError.snapshotRequiresFullFrame) {
        _ = try MobileTerminalRenderGridEnvelope.snapshot(deltaFrame)
    }
}

@Test func renderGridEnvelopeJSONRoundTripsRoleAndFrame() throws {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a",
        stateSeq: 12,
        columns: 8,
        rows: 1,
        text: "delta"
    )
    let envelope = try MobileTerminalRenderGridEnvelope.viewportDelta(
        frame.filteredRows([0], full: false)
    )
    let object = try envelope.jsonObject()
    let data = try JSONSerialization.data(withJSONObject: object)

    #expect(try MobileTerminalRenderGridEnvelope.decode(data) == envelope)
}

@Test func renderGridEnvelopeDecodeRejectsFullLiveDeltaPayloads() throws {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a",
        stateSeq: 13,
        columns: 8,
        rows: 1,
        text: "full"
    )
    let payload: [String: Any] = [
        "role": MobileTerminalRenderGridEnvelope.Role.viewportDelta.rawValue,
        "render_grid": try frame.jsonObject(),
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)

    #expect(throws: MobileTerminalRenderGridEnvelope.ValidationError.viewportDeltaRequiresDeltaFrame) {
        _ = try MobileTerminalRenderGridEnvelope.decode(data)
    }
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

@Test func renderGridDeltaEncodesNullDynamicColorAsReset() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 2,
        columns: 4,
        rows: 1,
        full: false,
        rowSpans: [],
        terminalForegroundIsPresent: true,
        terminalBackgroundIsPresent: true,
        terminalCursorColorIsPresent: true
    )

    let object = try frame.jsonObject()
    #expect(object["terminal_foreground"] is NSNull)
    #expect(object["terminal_background"] is NSNull)
    #expect(object["terminal_cursor_color"] is NSNull)

    let decoded = try MobileTerminalRenderGridFrame.decodeJSONObject(object)
    #expect(decoded.terminalForeground == nil)
    #expect(decoded.terminalBackground == nil)
    #expect(decoded.terminalCursorColor == nil)
    #expect(decoded.terminalForegroundIsPresent)
    #expect(decoded.terminalBackgroundIsPresent)
    #expect(decoded.terminalCursorColorIsPresent)

    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    #expect(vt.contains("\u{1B}]110\u{1B}\\"))
    #expect(vt.contains("\u{1B}]111\u{1B}\\"))
    #expect(vt.contains("\u{1B}]112\u{1B}\\"))
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

@Test func renderGridDeltaDropsHistoryAndModesButPreservesColors() throws {
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
        terminalForeground: "#010203",
        terminalBackground: "#040506",
        terminalCursorColor: "#070809",
        scrollbackRows: 3,
        scrollbackSpans: [.init(row: 0, column: 0, text: "sb")]
    )

    // A delta frame carries no scrollback and does not enter the alt screen or
    // replay modes; it only updates render state, then clears and repaints its
    // changed rows.
    #expect(frame.scrollbackRows == 0)
    #expect(frame.scrollbackSpans.isEmpty)
    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    #expect(!vt.contains("\u{1B}c"))
    #expect(!vt.contains("\u{1B}[?1049h"))
    #expect(!vt.contains("\u{1B}[?1000h"))
    #expect(vt.contains("\u{1B}]10;rgb:01/02/03\u{1B}\\"))
    #expect(vt.contains("\u{1B}]11;rgb:04/05/06\u{1B}\\"))
    #expect(vt.contains("\u{1B}]12;rgb:07/08/09\u{1B}\\"))
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
