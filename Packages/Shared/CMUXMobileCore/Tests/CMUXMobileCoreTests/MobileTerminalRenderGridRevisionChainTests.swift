import Testing
@testable import CMUXMobileCore

// A consumer can only trust a delta if it proves the delta was diffed against
// the exact frame the consumer last delivered. The history-rows chain misses
// dropped in-place repaints (history unchanged), which left silently stale
// rows on the phone. Every delta must therefore carry the render revision of
// its diff base on the wire.

@Test func renderGridInPlaceDeltaCarriesBaseRenderRevisionOnWire() throws {
    let previous = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 10,
        renderEpoch: "epoch-1",
        renderRevision: 7,
        columns: 8,
        rows: 2,
        rowSpans: [.init(row: 0, column: 0, text: "before")]
    ).emissionState
    let next = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 11,
        renderEpoch: "epoch-1",
        renderRevision: 8,
        columns: 8,
        rows: 2,
        rowSpans: [.init(row: 0, column: 0, text: "after!")]
    )

    let emission = try #require(try next.renderGridEmission(comparedTo: previous).emitted)

    #expect(!emission.frame.full)
    let payload = try emission.frame.jsonObject()
    #expect(payload["delta_base_render_revision"] as? UInt64 == 7)
}

@Test func renderGridScrollingDeltaCarriesBaseRenderRevisionOnWire() throws {
    let previous = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 20,
        renderEpoch: "epoch-1",
        renderRevision: 41,
        columns: 8,
        rows: 3,
        rowSpans: [
            .init(row: 0, column: 0, text: "aa"),
            .init(row: 1, column: 0, text: "bb"),
            .init(row: 2, column: 0, text: "cc"),
        ],
        anchor: .screen,
        historyRows: 100,
        rowSpaceRevision: 1
    ).emissionState
    let next = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 21,
        renderEpoch: "epoch-1",
        renderRevision: 42,
        columns: 8,
        rows: 3,
        rowSpans: [
            .init(row: 0, column: 0, text: "bb"),
            .init(row: 1, column: 0, text: "cc"),
            .init(row: 2, column: 0, text: "dd"),
        ],
        anchor: .screen,
        historyRows: 101,
        rowSpaceRevision: 1
    )

    let emission = try #require(try next.renderGridEmission(comparedTo: previous).emitted)

    #expect(!emission.frame.full)
    #expect(emission.frame.scrolledRows == 1)
    let payload = try emission.frame.jsonObject()
    #expect(payload["delta_base_render_revision"] as? UInt64 == 41)
}

@Test func renderGridFullFrameCarriesNoBaseRenderRevision() throws {
    let first = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 5,
        renderEpoch: "epoch-1",
        renderRevision: 3,
        columns: 8,
        rows: 2,
        rowSpans: [.init(row: 0, column: 0, text: "hello")]
    )

    let emission = try #require(try first.renderGridEmission(comparedTo: nil).emitted)

    #expect(emission.frame.full)
    let payload = try emission.frame.jsonObject()
    #expect(payload["delta_base_render_revision"] == nil)
}
