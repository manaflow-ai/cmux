import Foundation
import Testing
@testable import CMUXMobileSyncCore

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
