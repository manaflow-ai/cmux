import Testing
@testable import CMUXMobileCore

@Test func renderGridEmissionSuppressesUnchangedOriginModeSnapshot() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 48,
        columns: 8,
        rows: 2,
        rowSpans: [
            .init(row: 0, column: 0, text: "same"),
        ],
        modes: [
            .init(code: MobileTerminalRenderGridFrame.ModeSetting.decOriginModeCode, ansi: false, on: true),
        ]
    )
    let previous = frame.emissionState

    let emission = try frame.renderGridEmission(comparedTo: previous)

    #expect(emission == nil)
}

@Test func renderGridEmissionKeepsChangedOriginModeSnapshotFull() throws {
    let previous = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 48,
        columns: 8,
        rows: 2,
        rowSpans: [
            .init(row: 0, column: 0, text: "old"),
        ],
        modes: [
            .init(code: MobileTerminalRenderGridFrame.ModeSetting.decOriginModeCode, ansi: false, on: true),
        ]
    ).emissionState
    let next = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 49,
        columns: 8,
        rows: 2,
        rowSpans: [
            .init(row: 0, column: 0, text: "new"),
        ],
        modes: [
            .init(code: MobileTerminalRenderGridFrame.ModeSetting.decOriginModeCode, ansi: false, on: true),
        ]
    )

    let emission = try #require(try next.renderGridEmission(comparedTo: previous))

    #expect(emission.frame.full)
    #expect(emission.frame.rowSpans == next.rowSpans)
    #expect(emission.state == next.emissionState)
}

@Test func renderGridEmissionKeepsNonOriginChangesAsDeltas() throws {
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

    let emission = try #require(try next.renderGridEmission(comparedTo: previous))

    #expect(!emission.frame.full)
    #expect(emission.frame.clearedRows == [0])
    #expect(emission.frame.rowSpans == [.init(row: 0, column: 0, text: "new")])
}
