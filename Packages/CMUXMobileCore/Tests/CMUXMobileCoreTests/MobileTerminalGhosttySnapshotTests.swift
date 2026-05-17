import Foundation
import Testing
@testable import CMUXMobileCore

@Test func snapshotRoundTripsNormalScreenWithScrollback() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fixture(
        terminalID: "terminal-build",
        columns: 24,
        rows: 4,
        scrollbackLines: [
            "$ swift test",
            "Test Suite passed",
        ],
        visibleLines: [
            "$ cmux ios status",
            "Mobile Sync: enabled",
            "Listener: stopped",
            "Tailscale: available",
        ],
        streamOffset: 42
    )

    let encoded = try snapshot.encodedValidatedJSON()
    let decoded = try MobileTerminalGhosttySnapshot.decodeValidatedJSON(encoded)

    #expect(decoded == snapshot)
    #expect(decoded.scrollbackRows.count == 2)
    #expect(decoded.renderedVisibleLines == [
        "$ cmux ios status",
        "Mobile Sync: enabled",
        "Listener: stopped",
        "Tailscale: available",
    ])
    #expect(decoded.streamOffset == 42)
}

@Test func snapshotPreservesAlternateScreenTUIState() throws {
    let modes = MobileTerminalGhosttyModes(
        bracketedPaste: true,
        applicationCursorKeys: true,
        applicationKeypad: true,
        mouseTracking: true,
        cursorVisible: false
    )
    let snapshot = try MobileTerminalGhosttySnapshot.fixture(
        terminalID: "terminal-tui",
        columns: 20,
        rows: 3,
        visibleLines: [
            "LAZYGIT",
            "files branches log",
            "q quit",
        ],
        activeScreen: .alternate,
        modes: modes,
        cursor: MobileTerminalGhosttyCursor(column: 2, row: 1, isVisible: false, style: .bar),
        streamOffset: 9001
    )

    #expect(snapshot.activeScreen == .alternate)
    #expect(snapshot.modes == modes)
    #expect(snapshot.cursor == MobileTerminalGhosttyCursor(column: 2, row: 1, isVisible: false, style: .bar))
    #expect(snapshot.renderedVisibleLines[0] == "LAZYGIT")
    #expect(snapshot.streamOffset == 9001)
}

@Test func ghosttyTextBuilderSplitsVisibleAndScrollbackRows() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-1",
        columns: 10,
        rows: 3,
        scrollbackText: "history one\nhistory two\n",
        viewportText: "visible one\nvisible two\nprompt"
    )

    #expect(snapshot.scrollbackRows.map(\.trimmedPlainText) == ["history on", "history tw"])
    #expect(snapshot.renderedVisibleLines == ["visible on", "visible tw", "prompt"])
    #expect(snapshot.activeScreen == .primary)
}

@Test func ghosttyTextBuilderPadsVisibleRowsAndLimitsScrollback() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-2",
        columns: 8,
        rows: 4,
        scrollbackText: "old\nmiddle\nnew",
        viewportText: "prompt\n",
        maxScrollbackRows: 2,
        activeScreen: .alternate
    )

    #expect(snapshot.scrollbackRows.map(\.trimmedPlainText) == ["middle", "new"])
    #expect(snapshot.renderedVisibleLines == ["prompt", "", "", ""])
    #expect(snapshot.activeScreen == .alternate)
    #expect(snapshot.cursor.row == 1)
    #expect(snapshot.cursor.column == 0)
}

@Test func ghosttyTextBuilderKeepsTopAddressedRowsFromFullVTScreenExport() throws {
    let viewportText =
        "\u{001B}[1;1Hfirst line" +
        "\u{001B}[2;1Hsecond line" +
        "\u{001B}[3;1Hthird line" +
        "\u{001B}[8;1Hprompt"

    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-full-vt",
        columns: 20,
        rows: 8,
        scrollbackText: nil,
        viewportText: viewportText
    )

    #expect(snapshot.renderedVisibleLines[0] == "first line")
    #expect(snapshot.renderedVisibleLines[1] == "second line")
    #expect(snapshot.renderedVisibleLines[2] == "third line")
    #expect(snapshot.renderedVisibleLines[7] == "prompt")
}

@Test func ghosttyTextBuilderParsesSGRColorsAndFormatting() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-colored",
        columns: 24,
        rows: 2,
        scrollbackText: nil,
        viewportText: "plain \u{001B}[31;1mred\u{001B}[0m ok\n\u{001B}[48;2;1;2;3m bg \u{001B}[0m"
    )

    #expect(snapshot.renderedVisibleLines == ["plain red ok", " bg"])
    #expect(snapshot.visibleRows[0].cells[6].text == "r")
    #expect(snapshot.visibleRows[0].cells[6].style.foreground == MobileTerminalGhosttyColor(red: 205, green: 49, blue: 49))
    #expect(snapshot.visibleRows[0].cells[6].style.bold)
    #expect(snapshot.visibleRows[0].cells[10].style.foreground == nil)
    #expect(snapshot.visibleRows[1].cells[0].style.background == MobileTerminalGhosttyColor(red: 1, green: 2, blue: 3))
}

@Test func ghosttyTextBuilderParsesGhosttyVTFormatterColorSequences() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-ghostty-vt",
        columns: 24,
        rows: 2,
        scrollbackText: nil,
        viewportText: "\u{001B}]10;rgb:fd/ff/f1\u{001B}\\\u{001B}]11;rgb:27/28/22\u{001B}\\\u{001B}[0m\u{001B}[38;2;204;102;102mred\u{001B}[0m plain\r\n\u{001B}[0m\u{001B}[48;5;4m  \u{001B}[0m"
    )

    #expect(snapshot.renderedVisibleLines == ["red plain", ""])
    #expect(snapshot.visibleRows[0].cells[0].style.foreground == MobileTerminalGhosttyColor(red: 204, green: 102, blue: 102))
    #expect(snapshot.visibleRows[0].cells[4].style.foreground == nil)
    #expect(snapshot.visibleRows[1].cells[0].style.background == MobileTerminalGhosttyColor(red: 36, green: 114, blue: 200))
}

@Test func ghosttyTextBuilderAppliesCursorAddressingSequences() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-cursor-addressed",
        columns: 6,
        rows: 4,
        scrollbackText: nil,
        viewportText: "\u{001B}[2J\u{001B}[1;1H1----2\u{001B}[3;4Hmid\u{001B}[4;1H3----4"
    )

    #expect(snapshot.renderedVisibleLines == ["1----2", "", "   mid", "3----4"])
}

@Test func ghosttyTextBuilderErasesDisplayThroughCursor() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-erase-display",
        columns: 12,
        rows: 2,
        scrollbackText: nil,
        viewportText: "first line\nsecond line\u{001B}[2;7H\u{001B}[1J"
    )

    #expect(snapshot.renderedVisibleLines == ["", "       line"])
}

@Test func ghosttyTextBuilderPreservesFinalCursorPosition() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-cursor-position",
        columns: 12,
        rows: 4,
        scrollbackText: nil,
        viewportText: "\u{001B}[2J\u{001B}[1;1Hcursor target\u{001B}[3;5H@\u{001B}[3;5H"
    )

    #expect(snapshot.renderedVisibleLines == ["cursor targe", "t", "    @", ""])
    #expect(snapshot.cursor.column == 4)
    #expect(snapshot.cursor.row == 2)
    #expect(snapshot.cursor.isVisible == true)
}

@Test func ghosttyTextBuilderUsesLiveCursorWhenVTExportOmitsFinalPosition() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-live-cursor",
        columns: 12,
        rows: 4,
        scrollbackText: nil,
        viewportText: "1----------2\n|    @     |\n3----------4",
        cursor: MobileTerminalGhosttyCursor(column: 5, row: 1)
    )

    #expect(snapshot.renderedVisibleLines[1] == "|    @     |")
    #expect(snapshot.cursor.column == 5)
    #expect(snapshot.cursor.row == 1)
}

@Test func ghosttyTextBuilderAppliesCursorVisibilityToLiveCursor() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-live-hidden-cursor",
        columns: 12,
        rows: 2,
        scrollbackText: nil,
        viewportText: "\u{001B}[?25lhidden",
        cursor: MobileTerminalGhosttyCursor(column: 3, row: 0)
    )

    #expect(snapshot.cursor.column == 3)
    #expect(snapshot.cursor.row == 0)
    #expect(snapshot.cursor.isVisible == false)
    #expect(snapshot.modes.cursorVisible == false)
}

@Test func ghosttyTextBuilderWindowsExtraExportRowsAroundCursor() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-export-window",
        columns: 16,
        rows: 3,
        scrollbackText: nil,
        viewportText: "stale one\nstale two\ncurrent one\ncurrent two\nprompt\u{001B}[5;7H",
        cursor: MobileTerminalGhosttyCursor(column: 6, row: 2)
    )

    #expect(snapshot.renderedVisibleLines == ["current one", "current two", "prompt"])
    #expect(snapshot.cursor.column == 6)
    #expect(snapshot.cursor.row == 2)
}

@Test func ghosttyTextBuilderWrapsOverflowingRowsLikeTerminalAutowrap() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-autowrap",
        columns: 8,
        rows: 3,
        scrollbackText: nil,
        viewportText: "\u{001B}[1;1Habcdefghi"
    )

    #expect(snapshot.renderedVisibleLines == ["abcdefgh", "i", ""])
    #expect(snapshot.visibleRows[0].isWrapped)
    #expect(snapshot.cursor.column == 1)
    #expect(snapshot.cursor.row == 1)
}

@Test func ghosttyTextBuilderDoesNotAddBlankWrapRowForExactlyFullRows() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-exact-width",
        columns: 4,
        rows: 2,
        scrollbackText: nil,
        viewportText: "\u{001B}[1;1Habcd"
    )

    #expect(snapshot.renderedVisibleLines == ["abcd", ""])
    #expect(snapshot.visibleRows[0].isWrapped == false)
    #expect(snapshot.cursor.column == 3)
    #expect(snapshot.cursor.row == 0)
}

@Test func ghosttyTextBuilderTabsAtLastColumnDoNotLoopForever() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-tab-last-column",
        columns: 4,
        rows: 2,
        scrollbackText: nil,
        viewportText: "abc\t"
    )

    #expect(snapshot.renderedVisibleLines == ["abc", ""])
    #expect(snapshot.cursor.column == 3)
    #expect(snapshot.cursor.row == 0)
}

@Test func ghosttyTextBuilderAlignsSparseViewportRowsToCursorRow() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-sparse-cursor",
        columns: 24,
        rows: 6,
        scrollbackText: nil,
        viewportText: "line one\nline two\u{001B}[6;9H"
    )

    #expect(snapshot.renderedVisibleLines == ["", "", "", "", "line one", "line two"])
    #expect(snapshot.cursor.column == 8)
    #expect(snapshot.cursor.row == 5)
}

@Test func ghosttyTextBuilderDoesNotShiftRowsToHiddenLiveCursor() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-hidden-live-cursor",
        columns: 24,
        rows: 6,
        scrollbackText: nil,
        viewportText: "\u{001B}[?25lline one\nline two",
        cursor: MobileTerminalGhosttyCursor(column: 8, row: 5)
    )

    #expect(snapshot.renderedVisibleLines == ["line one", "line two", "", "", "", ""])
    #expect(snapshot.cursor.column == 8)
    #expect(snapshot.cursor.row == 5)
    #expect(snapshot.cursor.isVisible == false)
}

@Test func ghosttyTextBuilderDoesNotShiftRowsForNormalNewlineCursorMovement() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-normal-newline",
        columns: 12,
        rows: 4,
        scrollbackText: nil,
        viewportText: "prompt\n"
    )

    #expect(snapshot.renderedVisibleLines == ["prompt", "", "", ""])
    #expect(snapshot.cursor.column == 0)
    #expect(snapshot.cursor.row == 1)
}

@Test func ghosttyTextBuilderHonorsCursorVisibilitySequences() throws {
    let hiddenSnapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-hidden-cursor",
        columns: 8,
        rows: 2,
        scrollbackText: nil,
        viewportText: "\u{001B}[?25lhidden"
    )
    let visibleSnapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-visible-cursor",
        columns: 8,
        rows: 2,
        scrollbackText: nil,
        viewportText: "\u{001B}[?25lhidden\u{001B}[?25hshown"
    )

    #expect(hiddenSnapshot.cursor.isVisible == false)
    #expect(hiddenSnapshot.modes.cursorVisible == false)
    #expect(visibleSnapshot.cursor.isVisible == true)
    #expect(visibleSnapshot.modes.cursorVisible == true)
}

@Test func ghosttyTextBuilderParsesSGRUnderlineSubparameters() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-underlines",
        columns: 32,
        rows: 1,
        scrollbackText: nil,
        viewportText: "\u{001B}[4:2mdouble\u{001B}[0m \u{001B}[4:3mcurly\u{001B}[0m \u{001B}[4:4mdotted\u{001B}[0m \u{001B}[4:5mdashed"
    )

    #expect(snapshot.visibleRows[0].cells[0].style.underline == .double)
    #expect(snapshot.visibleRows[0].cells[0].style.dim == false)
    #expect(snapshot.visibleRows[0].cells[7].style.underline == .curly)
    #expect(snapshot.visibleRows[0].cells[13].style.underline == .dotted)
    #expect(snapshot.visibleRows[0].cells[20].style.underline == .dashed)
}

@Test func ghosttyTextBuilderConsumesUnsupportedUnderlineColorWithoutLeakingStyle() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-underline-color",
        columns: 16,
        rows: 1,
        scrollbackText: nil,
        viewportText: "\u{001B}[58;2;1;2;3mplain \u{001B}[31mred"
    )

    #expect(snapshot.visibleRows[0].cells[0].style.foreground == nil)
    #expect(snapshot.visibleRows[0].cells[0].style.dim == false)
    #expect(snapshot.visibleRows[0].cells[0].style.italic == false)
    #expect(snapshot.visibleRows[0].cells[6].style.foreground == MobileTerminalGhosttyColor(red: 205, green: 49, blue: 49))
    #expect(snapshot.visibleRows[0].cells[6].style.dim == false)
    #expect(snapshot.visibleRows[0].cells[6].style.italic == false)
}

@Test func ghosttyTextBuilderDropsOSCControlSequences() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-osc",
        columns: 20,
        rows: 1,
        scrollbackText: nil,
        viewportText: "\u{001B}]10;rgb:fd/ff/f1\u{001B}\\ready"
    )

    #expect(snapshot.renderedVisibleLines == ["ready"])
    #expect(snapshot.visibleRows[0].cells[0].text == "r")
}

@Test func ghosttyTextBuilderSplitsCRLFRows() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: "terminal-crlf",
        columns: 20,
        rows: 2,
        scrollbackText: nil,
        viewportText: "first\r\nsecond"
    )

    #expect(snapshot.renderedVisibleLines == ["first", "second"])
}

@Test func renderedLinesPreserveLeadingWhitespace() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fixture(
        terminalID: "terminal-indented",
        columns: 16,
        rows: 2,
        visibleLines: [
            "  indented",
            "    nested",
        ]
    )

    #expect(snapshot.renderedVisibleLines == [
        "  indented",
        "    nested",
    ])
}

@Test func snapshotPreservesStyledCellsAndLinks() throws {
    var cells = Array(repeating: MobileTerminalGhosttyCell.blank, count: 8)
    cells[0] = MobileTerminalGhosttyCell(
        text: "c",
        style: MobileTerminalGhosttyCellStyle(
            foreground: MobileTerminalGhosttyColor(red: 72, green: 199, blue: 142),
            background: MobileTerminalGhosttyColor(red: 16, green: 24, blue: 32),
            bold: true,
            underline: .single
        ),
        hyperlinkURI: "https://cmux.dev"
    )
    cells[1] = MobileTerminalGhosttyCell(text: "m", style: cells[0].style)
    cells[2] = MobileTerminalGhosttyCell(text: "u", style: cells[0].style)
    cells[3] = MobileTerminalGhosttyCell(text: "x", style: cells[0].style)
    let styledRow = MobileTerminalGhosttyRow(cells: cells)
    let blankRow = MobileTerminalGhosttyRow(cells: Array(repeating: .blank, count: 8))
    let snapshot = try MobileTerminalGhosttySnapshot(
        terminalID: "terminal-styled",
        gridSize: try MobileTerminalGridSize(columns: 8, rows: 2),
        activeScreen: .primary,
        scrollbackRows: [],
        visibleRows: [styledRow, blankRow],
        cursor: MobileTerminalGhosttyCursor(column: 4, row: 0),
        modes: MobileTerminalGhosttyModes(),
        streamOffset: 10,
        generatedAt: Date(timeIntervalSince1970: 0)
    )

    let decoded = try MobileTerminalGhosttySnapshot.decodeValidatedJSON(
        try snapshot.encodedValidatedJSON()
    )

    #expect(decoded.visibleRows[0].cells[0].style.bold)
    #expect(decoded.visibleRows[0].cells[0].style.foreground == MobileTerminalGhosttyColor(red: 72, green: 199, blue: 142))
    #expect(decoded.visibleRows[0].cells[0].hyperlinkURI == "https://cmux.dev")
    #expect(decoded.visibleRows[0].trimmedPlainText == "cmux")
}

@Test func decodeRejectsIncompatibleSnapshotVersion() throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fixture(
        terminalID: "terminal-old",
        columns: 10,
        rows: 1,
        visibleLines: ["old"]
    )
    var object = try JSONSerialization.jsonObject(with: try snapshot.encodedValidatedJSON()) as! [String: Any]
    object["schemaVersion"] = 999
    let data = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: MobileTerminalGhosttySnapshotError.unsupportedSchemaVersion(999)) {
        try MobileTerminalGhosttySnapshot.decodeValidatedJSON(data)
    }
}

@Test func validationRejectsMalformedRowsAndCursor() throws {
    #expect(throws: MobileTerminalGhosttySnapshotError.invalidVisibleRowCount(expected: 2, actual: 1)) {
        _ = try MobileTerminalGhosttySnapshot(
            terminalID: "terminal-short",
            gridSize: try MobileTerminalGridSize(columns: 4, rows: 2),
            activeScreen: .primary,
            scrollbackRows: [],
            visibleRows: [MobileTerminalGhosttyRow(cells: Array(repeating: .blank, count: 4))],
            cursor: MobileTerminalGhosttyCursor(column: 0, row: 0),
            modes: MobileTerminalGhosttyModes(),
            streamOffset: 0
        )
    }

    #expect(throws: MobileTerminalGhosttySnapshotError.cursorOutOfBounds) {
        _ = try MobileTerminalGhosttySnapshot.fixture(
            terminalID: "terminal-cursor",
            columns: 4,
            rows: 2,
            visibleLines: ["ok"],
            cursor: MobileTerminalGhosttyCursor(column: 4, row: 0)
        )
    }
}
