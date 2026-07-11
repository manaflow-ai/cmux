import Foundation
import Testing
@testable import CMUXMobileCore

@Test func renderGridRoundTripsRenderRevisionAndBidirectionalHistory() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-window",
        stateSeq: 7,
        renderRevision: 41,
        columns: 12,
        rows: 1,
        rowSpans: [.init(row: 0, column: 0, text: "visible")],
        scrollbackRows: 1,
        scrollbackSpans: [.init(row: 0, column: 0, text: "older")],
        scrollForwardRows: 1,
        scrollForwardSpans: [.init(row: 0, column: 0, text: "newer")]
    )

    let decoded = try MobileTerminalRenderGridFrame.decodeJSONObject(frame.jsonObject())
    #expect(decoded == frame)
    #expect(decoded.renderRevision == 41)
    #expect(decoded.scrollForwardRows == 1)

    let replay = try #require(String(data: frame.vtReplacementBytes(), encoding: .utf8))
    let older = try #require(replay.range(of: "older"))
    let visible = try #require(replay.range(of: "visible"))
    let newer = try #require(replay.range(of: "newer"))
    #expect(older.lowerBound < visible.lowerBound)
    #expect(visible.lowerBound < newer.lowerBound)
}
@Test func renderGridDeltaPreservesRenderRevisionButDropsHistoryWindows() throws {
    let full = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-window",
        stateSeq: 8,
        renderRevision: 42,
        columns: 12,
        rows: 1,
        rowSpans: [.init(row: 0, column: 0, text: "visible")],
        scrollbackRows: 1,
        scrollbackSpans: [.init(row: 0, column: 0, text: "older")],
        scrollForwardRows: 1,
        scrollForwardSpans: [.init(row: 0, column: 0, text: "newer")]
    )

    let delta = try full.filteredRows([0], full: false)
    #expect(delta.renderRevision == 42)
    #expect(delta.scrollbackRows == 0)
    #expect(delta.scrollForwardRows == 0)
}
