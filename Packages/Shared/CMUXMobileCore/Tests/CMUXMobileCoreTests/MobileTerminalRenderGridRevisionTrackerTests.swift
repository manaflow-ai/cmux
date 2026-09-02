import Testing
@testable import CMUXMobileCore

private struct RenderGridRevisionFixture {
    var tracker = MobileTerminalRenderGridRevisionTracker(renderEpoch: "epoch-1")

    mutating func record(
        text: String,
        columns: Int = 12,
        rows: Int = 2,
        stateSeq: UInt64 = 1
    ) throws -> MobileTerminalRenderGridRevisionTracker.Identity {
        let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: "surface-a",
            stateSeq: stateSeq,
            columns: columns,
            rows: rows,
            text: text
        )
        return tracker.record(fullFrame: frame)
    }
}

@Test func unchangedReplayKeepsContentRevisionButAdvancesEmissionIdentity() throws {
    var fixture = RenderGridRevisionFixture()
    let first = try fixture.record(text: "same", stateSeq: 1)
    let replay = try fixture.record(text: "same", stateSeq: 99)

    #expect(first.renderRevision == 1)
    #expect(replay.renderRevision == first.renderRevision)
    #expect(replay.emissionRevision == first.emissionRevision + 1)
}

@Test func oneVisibleOutputBatchAdvancesContentOnce() throws {
    var fixture = RenderGridRevisionFixture()
    let baseline = try fixture.record(text: "before", stateSeq: 1)
    let changed = try fixture.record(text: "after", stateSeq: 2)
    let sameBatchReplay = try fixture.record(text: "after", stateSeq: 2)

    #expect(changed.renderRevision == baseline.renderRevision + 1)
    #expect(sameBatchReplay.renderRevision == changed.renderRevision)
    #expect(sameBatchReplay.emissionRevision == changed.emissionRevision + 1)
}

@Test func emissionStateCarriesTheCanonicalContentIdentity() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 4,
        columns: 8,
        rows: 2,
        rowSpans: [.init(row: 0, column: 0, text: "same")],
        scrollbackRows: 1,
        scrollbackSpans: [.init(row: 0, column: 0, text: "history")]
    )
    let state = frame.emissionState
    let content = try #require(state.content)
    var tracker = MobileTerminalRenderGridRevisionTracker(renderEpoch: "epoch-1")

    let first = tracker.record(fullFrame: frame, content: content)
    let replay = tracker.record(fullFrame: frame, content: content)

    #expect(content.rowSignatures == state.rowSignatures)
    #expect(first.renderRevision == replay.renderRevision)
    #expect(replay.emissionRevision == first.emissionRevision + 1)
}

@Test func renderedContentCanonicalizesSpanOrderWithoutChangingIdentity() throws {
    let style = MobileTerminalRenderGridFrame.Style(id: 2, bold: true)
    let first = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 1,
        columns: 8,
        rows: 2,
        styles: [.default, style],
        rowSpans: [
            .init(row: 1, column: 3, styleID: 2, text: "end"),
            .init(row: 0, column: 0, styleID: 2, text: "start"),
        ]
    )
    let second = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 99,
        columns: 8,
        rows: 2,
        styles: [.default, style],
        rowSpans: [
            .init(row: 0, column: 0, styleID: 2, text: "start"),
            .init(row: 1, column: 3, styleID: 2, text: "end"),
        ]
    )

    #expect(first.renderedContent() == second.renderedContent())
}

@Test func observingARequestCaptureAdvancesContentWithoutAnEmission() throws {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "surface-a",
        stateSeq: 1,
        columns: 8,
        rows: 1,
        text: "visible"
    )
    var tracker = MobileTerminalRenderGridRevisionTracker(renderEpoch: "epoch-1")

    let first = tracker.observe(fullFrame: frame)
    let replay = tracker.observe(fullFrame: frame)

    #expect(first.renderRevision == 1)
    #expect(first.emissionRevision == 0)
    #expect(replay == first)
}

@Test func observingAfterAnEmissionDoesNotReuseItsEmissionIdentity() throws {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "surface-a",
        stateSeq: 1,
        columns: 8,
        rows: 1,
        text: "visible"
    )
    var tracker = MobileTerminalRenderGridRevisionTracker(renderEpoch: "epoch-1")

    let emitted = tracker.record(fullFrame: frame)
    let observed = tracker.observe(fullFrame: frame)

    #expect(emitted.emissionRevision == 1)
    #expect(observed.renderRevision == emitted.renderRevision)
    #expect(observed.emissionRevision == 0)
}

@Test func resizeAdvancesContentRevision() throws {
    var fixture = RenderGridRevisionFixture()
    let baseline = try fixture.record(text: "size", columns: 12, rows: 2)
    let resized = try fixture.record(text: "size", columns: 8, rows: 3)

    #expect(resized.renderRevision == baseline.renderRevision + 1)
    #expect(resized.emissionRevision == baseline.emissionRevision + 1)
}

@Test func emissionDeltaUsesEmissionIdentityWhileContentTokenRemainsStable() throws {
    let previous = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 10,
        renderEpoch: "epoch-1",
        renderRevision: 4,
        emissionRevision: 9,
        columns: 8,
        rows: 2,
        rowSpans: [.init(row: 0, column: 0, text: "old")]
    ).emissionState
    let next = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 11,
        renderEpoch: "epoch-1",
        renderRevision: 5,
        emissionRevision: 10,
        columns: 8,
        rows: 2,
        rowSpans: [.init(row: 0, column: 0, text: "new")]
    )

    let emitted = try #require(try next.renderGridEmission(comparedTo: previous).emitted)

    #expect(emitted.frame.deltaBaseRenderRevision == 4)
    #expect(emitted.frame.deltaBaseEmissionRevision == 9)
}

@Test func deltaEmissionStateRetainsTheCompleteRenderedBaseline() throws {
    let previous = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 1,
        renderEpoch: "epoch-1",
        renderRevision: 1,
        emissionRevision: 1,
        columns: 12,
        rows: 2,
        rowSpans: [
            .init(row: 0, column: 0, text: "old"),
            .init(row: 1, column: 0, text: "unchanged"),
        ]
    ).emissionState
    let next = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 2,
        renderEpoch: "epoch-1",
        renderRevision: 2,
        emissionRevision: 2,
        columns: 12,
        rows: 2,
        rowSpans: [
            .init(row: 0, column: 0, text: "new"),
            .init(row: 1, column: 0, text: "unchanged"),
        ]
    )

    let emitted = try #require(try next.renderGridEmission(comparedTo: previous).emitted)

    #expect(emitted.frame.rowSpans.map(\.row) == [0])
    #expect(emitted.state.rowSignatures == next.rowSignatures())
    #expect(emitted.state.rowSignatures[1] == next.rowSignatures()[1])
}

@Test func scrollbackStyleChangesAdvanceTheContentRevision() throws {
    let plain = MobileTerminalRenderGridFrame.Style(id: 1)
    let bold = MobileTerminalRenderGridFrame.Style(id: 1, bold: true)
    func frame(style: MobileTerminalRenderGridFrame.Style) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: "surface-a",
            stateSeq: 1,
            renderEpoch: "epoch-1",
            columns: 8,
            rows: 1,
            styles: [.default, style],
            rowSpans: [.init(row: 0, column: 0, styleID: 1, text: "live")],
            scrollbackRows: 1,
            scrollbackSpans: [.init(row: 0, column: 0, styleID: 1, text: "history")]
        )
    }

    var tracker = MobileTerminalRenderGridRevisionTracker(renderEpoch: "epoch-1")
    let first = tracker.record(fullFrame: try frame(style: plain))
    let changed = tracker.record(fullFrame: try frame(style: bold))

    #expect(changed.renderRevision == first.renderRevision + 1)
}

@Test func nonVisualModeMetadataDoesNotAdvanceTheContentRevision() throws {
    func frame(modes: [MobileTerminalRenderGridFrame.ModeSetting]) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: "surface-a",
            stateSeq: 1,
            renderEpoch: "epoch-1",
            columns: 8,
            rows: 1,
            rowSpans: [.init(row: 0, column: 0, text: "same")],
            modes: modes
        )
    }

    var tracker = MobileTerminalRenderGridRevisionTracker(renderEpoch: "epoch-1")
    let first = tracker.record(fullFrame: try frame(modes: []))
    let metadataOnly = tracker.record(
        fullFrame: try frame(modes: [.init(code: 2004, ansi: true, on: true)])
    )

    #expect(metadataOnly.renderRevision == first.renderRevision)
    #expect(metadataOnly.emissionRevision == first.emissionRevision + 1)
}
