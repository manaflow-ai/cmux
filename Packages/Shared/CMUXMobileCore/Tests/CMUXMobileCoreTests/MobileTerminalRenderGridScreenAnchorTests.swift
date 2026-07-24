import Foundation
import Testing
@testable import CMUXMobileCore

private func screenFrame(
    stateSeq: UInt64,
    rows: [String],
    historyRows: UInt64,
    rowSpaceRevision: UInt64 = 7,
    scrollbackRows: Int = 0,
    scrollbackSpans: [MobileTerminalRenderGridFrame.RowSpan] = [],
    cursorRow: Int? = nil
) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: stateSeq,
        renderEpoch: "epoch-1",
        renderRevision: stateSeq,
        columns: 12,
        rows: rows.count,
        cursor: cursorRow.map { .init(row: $0, column: 0) },
        rowSpans: rows.enumerated().compactMap { row, text in
            text.isEmpty ? nil : .init(row: row, column: 0, text: text)
        },
        scrollbackRows: scrollbackRows,
        scrollbackSpans: scrollbackSpans,
        anchor: .screen,
        historyRows: historyRows,
        rowSpaceRevision: rowSpaceRevision
    )
}

@Test func screenAnchorEmissionTurnsHistoryGrowthIntoScrolledDelta() throws {
    let previous = try screenFrame(
        stateSeq: 10,
        rows: ["alpha", "bravo", "charlie", "delta"],
        historyRows: 100
    ).emissionState
    // Two rows scrolled into history; the surviving rows shifted up and two
    // new rows appeared at the bottom (one of them blank).
    let next = try screenFrame(
        stateSeq: 11,
        rows: ["charlie", "delta", "echo", ""],
        historyRows: 102
    )

    let emission = try #require(try next.renderGridEmission(comparedTo: previous).emitted)

    #expect(!emission.frame.full)
    #expect(emission.frame.scrolledRows == 2)
    // Shifted rows match, so only the non-blank new bottom row repaints.
    #expect(emission.frame.clearedRows == [2])
    #expect(emission.frame.rowSpans.map(\.text) == ["echo"])
    #expect(emission.frame.deltaBaseHistoryRows == 100)
    #expect(emission.frame.scrollbackRows == 0)
}

@Test func screenAnchorEmissionFallsBackToRepaintOnRowSpaceRevisionChange() throws {
    let previous = try screenFrame(
        stateSeq: 10,
        rows: ["alpha", "bravo", "charlie", "delta"],
        historyRows: 100,
        rowSpaceRevision: 7
    ).emissionState
    // Same content shift, but eviction bumped the row-space revision: the
    // growth arithmetic is invalid, so the emission repaints in place.
    let next = try screenFrame(
        stateSeq: 11,
        rows: ["charlie", "delta", "echo", ""],
        historyRows: 100,
        rowSpaceRevision: 8
    )

    let emission = try #require(try next.renderGridEmission(comparedTo: previous).emitted)

    #expect(!emission.frame.full)
    #expect(emission.frame.scrolledRows == 0)
    #expect(Set(emission.frame.clearedRows) == [0, 1, 2, 3])
}

@Test func screenAnchorEmissionRequestsScrollbackForBursts() throws {
    let previous = try screenFrame(
        stateSeq: 10,
        rows: ["alpha", "bravo", "charlie", "delta"],
        historyRows: 100
    ).emissionState
    // Six rows scrolled through a four-row grid: two history rows were never
    // captured, so the first pass must ask for a re-export carrying them.
    let burst = try screenFrame(
        stateSeq: 11,
        rows: ["golf", "hotel", "india", "juliet"],
        historyRows: 106
    )

    let firstPass = try burst.renderGridEmission(comparedTo: previous)
    #expect(firstPass == .needsScrollback(rows: 2))

    let carried = try screenFrame(
        stateSeq: 11,
        rows: ["golf", "hotel", "india", "juliet"],
        historyRows: 106,
        scrollbackRows: 2,
        scrollbackSpans: [
            .init(row: 0, column: 0, text: "echo"),
            .init(row: 1, column: 0, text: "foxtrot"),
        ]
    )
    let emission = try #require(
        try carried.renderGridEmission(
            comparedTo: previous,
            allowScrollbackRequest: false
        ).emitted
    )

    #expect(!emission.frame.full)
    // Pushes = grid rows + carried missed rows.
    #expect(emission.frame.scrolledRows == 6)
    #expect(emission.frame.scrollbackRows == 2)
    #expect(emission.frame.scrollbackSpans.map(\.text) == ["echo", "foxtrot"])
    #expect(emission.frame.deltaBaseHistoryRows == 100)
    #expect(Set(emission.frame.clearedRows) == [0, 1, 2, 3])
}

@Test func screenAnchorEmissionRequestsDeepScrollbackForFulls() throws {
    let first = try screenFrame(
        stateSeq: 10,
        rows: ["alpha", "bravo", "charlie", "delta"],
        historyRows: 100
    )

    // No prior state: the emission is a full frame, and a screen-anchored
    // consumer needs it to carry deep scrollback before it can be emitted.
    let request = try first.renderGridEmission(comparedTo: nil, fullScrollbackTarget: 4000)
    #expect(request == .needsScrollback(rows: 4000))

    let carried = try screenFrame(
        stateSeq: 10,
        rows: ["alpha", "bravo", "charlie", "delta"],
        historyRows: 100,
        scrollbackRows: 100,
        scrollbackSpans: (0..<100).map { .init(row: $0, column: 0, text: "h\($0)") }
    )
    let emission = try #require(
        try carried.renderGridEmission(
            comparedTo: nil,
            fullScrollbackTarget: 4000,
            allowScrollbackRequest: false
        ).emitted
    )
    #expect(emission.frame.full)
    #expect(emission.frame.scrollbackRows == 100)
}

@Test func screenAnchorScrollDeltaReplayScrollsThenRepaints() throws {
    let delta = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 11,
        renderEpoch: "epoch-1",
        renderRevision: 11,
        columns: 12,
        rows: 4,
        cursor: .init(row: 3, column: 0),
        full: false,
        clearedRows: [2],
        rowSpans: [.init(row: 2, column: 0, text: "echo")],
        anchor: .screen,
        scrolledRows: 2,
        historyRows: 102
    )

    let bytes = delta.vtPatchBytes()
    let replay = String(decoding: bytes, as: UTF8.self)

    // Scroll prologue: reset margins, feed from the bottom row so the top
    // rows enter local scrollback, then repaint the changed row.
    let prologueRange = try #require(replay.range(of: "\u{1B}[r\u{1B}[4;1H"))
    let feedRange = try #require(replay.range(of: "\r\n\r\n"))
    let repaintRange = try #require(replay.range(of: "\u{1B}[3;1H\u{1B}[2K"))
    #expect(prologueRange.upperBound <= feedRange.lowerBound)
    #expect(feedRange.upperBound <= repaintRange.lowerBound)
    #expect(replay.contains("echo"))
    // Cursor restored last.
    #expect(replay.range(of: "\u{1B}[4;1H", options: .backwards)!.lowerBound > repaintRange.lowerBound)
}

@Test func screenAnchorBurstReplayFlowsMissedRowsThroughGrid() throws {
    let burst = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 11,
        renderEpoch: "epoch-1",
        renderRevision: 11,
        columns: 12,
        rows: 4,
        cursor: .init(row: 3, column: 0),
        full: false,
        clearedRows: [0, 1, 2, 3],
        rowSpans: [
            .init(row: 0, column: 0, text: "golf"),
            .init(row: 1, column: 0, text: "hotel"),
            .init(row: 2, column: 0, text: "india"),
            .init(row: 3, column: 0, text: "juliet"),
        ],
        scrollbackRows: 2,
        scrollbackSpans: [
            .init(row: 0, column: 0, text: "echo"),
            .init(row: 1, column: 0, text: "foxtrot"),
        ],
        anchor: .screen,
        scrolledRows: 6,
        historyRows: 106
    )

    let replay = String(decoding: burst.vtPatchBytes(), as: UTF8.self)

    // Missed rows flow through the grid oldest-first, before the repaint.
    let echoRange = try #require(replay.range(of: "echo"))
    let foxtrotRange = try #require(replay.range(of: "foxtrot"))
    let golfRange = try #require(replay.range(of: "golf"))
    #expect(echoRange.upperBound <= foxtrotRange.lowerBound)
    #expect(foxtrotRange.upperBound <= golfRange.lowerBound)
    // Total line feeds in the prologue equal the scrolled amount.
    let lineFeeds = replay.components(separatedBy: "\r\n").count - 1
    #expect(lineFeeds >= 6)
}

@Test func screenAnchorFieldsRoundTripThroughCoding() throws {
    let frame = try screenFrame(
        stateSeq: 11,
        rows: ["alpha", "bravo"],
        historyRows: 102,
        rowSpaceRevision: 9
    )
    var delta = try frame.filteredRows(
        [0],
        full: false,
        scrolledRows: 1,
        deltaBaseHistoryRows: 101
    )
    delta.cursor = nil

    let decoded = try MobileTerminalRenderGridFrame.decode(
        JSONEncoder().encode(delta)
    )

    #expect(decoded.anchor == .screen)
    #expect(decoded.scrolledRows == 1)
    #expect(decoded.historyRows == 102)
    #expect(decoded.rowSpaceRevision == 9)
    #expect(decoded.deltaBaseHistoryRows == 101)
}

@Test func viewportAnchoredEmissionKeepsLegacyBehavior() throws {
    let previous = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a",
        stateSeq: 50,
        columns: 8,
        rows: 2,
        text: "old\nsame"
    ).emissionState
    let next = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a",
        stateSeq: 51,
        columns: 8,
        rows: 2,
        text: "new\nsame"
    )

    let emission = try #require(try next.renderGridEmission(comparedTo: previous).emitted)

    #expect(emission.frame.scrolledRows == 0)
    #expect(emission.frame.anchor == .viewport)
    #expect(emission.frame.deltaBaseHistoryRows == nil)
}

@Test func scrollingDeltaIsNeverReplaceable() throws {
    // Mirrors MobileShellComposite's queue-coalescing rule: a delta whose
    // line feeds push rows into local scrollback must never be superseded.
    let scrolling = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 11,
        columns: 12,
        rows: 2,
        full: false,
        clearedRows: [0, 1],
        rowSpans: [.init(row: 0, column: 0, text: "x")],
        anchor: .screen,
        scrolledRows: 1,
        historyRows: 1
    )
    #expect(scrolling.scrolledRows == 1)
}
