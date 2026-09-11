import CMUXMobileCore
import Testing
@testable import CmuxMobileTerminalKit

/// Verifies producer or history changes force retained mirrors to hydrate.
@Test func retainedMirrorFreshnessFailsClosed() throws {
    var state = MobileTerminalMirrorState()
    let delivered = try MobileTerminalRenderGridFrame(
        surfaceID: "surface",
        stateSeq: 10,
        renderEpoch: "epoch-1",
        renderRevision: 1,
        columns: 80,
        rows: 4,
        full: true,
        rowSpans: [],
        scrollbackRows: 20,
        anchor: .screen,
        historyRows: 20,
        rowSpaceRevision: 1
    )
    state.record(delivered)
    state.prepareForReconnect(hasDeliveredFrame: true)

    var sameHistory = delivered
    sameHistory.stateSeq = 11
    sameHistory.renderRevision = 2
    #expect(!state.requiresHydration(for: sameHistory))

    var advancedHistory = sameHistory
    advancedHistory.historyRows = 21
    #expect(state.requiresHydration(for: advancedHistory))

    var replacedProducer = sameHistory
    replacedProducer.renderEpoch = "epoch-2"
    #expect(state.requiresHydration(for: replacedProducer))
}

/// Verifies a live full frame cannot replace retained metadata with a stale
/// producer and make the old local scrollback look reusable.
@Test func retainedMirrorRejectsLiveFullFrameWithChangedProducer() throws {
    var state = MobileTerminalMirrorState()
    let delivered = try MobileTerminalRenderGridFrame(
        surfaceID: "surface",
        stateSeq: 10,
        renderEpoch: "epoch-1",
        renderRevision: 1,
        columns: 80,
        rows: 4,
        full: true,
        rowSpans: [],
        scrollbackRows: 20,
        anchor: .screen,
        historyRows: 20,
        rowSpaceRevision: 1
    )
    state.record(delivered)
    state.prepareForReconnect(hasDeliveredFrame: true)

    var replacement = delivered
    replacement.renderEpoch = "epoch-2"
    replacement.historyRows = 21
    state.record(replacement)

    #expect(state.hydrationNeeded)
    #expect(!state.retainedAcrossReconnect)
    #expect(state.requiresHydration(for: delivered))
}

/// Verifies a producer change after a matching zero-row replay cannot keep the
/// old producer's scrollback baseline marked as hydrated.
@Test func liveProducerChangeAfterRetainedReplayRequiresHydration() throws {
    var state = MobileTerminalMirrorState()
    let delivered = try MobileTerminalRenderGridFrame(
        surfaceID: "surface",
        stateSeq: 10,
        renderEpoch: "epoch-1",
        renderRevision: 1,
        columns: 80,
        rows: 4,
        full: true,
        rowSpans: [],
        scrollbackRows: 20,
        anchor: .screen,
        historyRows: 20,
        rowSpaceRevision: 1
    )
    state.record(delivered)
    state.prepareForReconnect(hasDeliveredFrame: true)

    var replay = delivered
    replay.stateSeq = 11
    replay.renderRevision = 2
    replay.scrollbackRows = 0
    replay.scrollbackSpans = []
    state.record(replay)
    #expect(!state.hydrationNeeded)

    var replacement = replay
    replacement.stateSeq = 12
    replacement.renderRevision = 3
    replacement.renderEpoch = "epoch-2"
    replacement.historyRows = 21
    replacement.rowSpaceRevision = 2
    state.record(replacement)

    #expect(state.hydrationNeeded)
    #expect(state.requiresHydration(for: replacement))
}

/// Verifies normal history growth after a retained replay does not invalidate
/// an otherwise healthy same-producer mirror.
@Test func sameProducerHistoryGrowthAfterRetainedReplayStaysHydrated() throws {
    var state = MobileTerminalMirrorState()
    let delivered = try MobileTerminalRenderGridFrame(
        surfaceID: "surface",
        stateSeq: 10,
        renderEpoch: "epoch-1",
        renderRevision: 1,
        columns: 80,
        rows: 4,
        full: true,
        rowSpans: [],
        scrollbackRows: 20,
        anchor: .screen,
        historyRows: 20,
        rowSpaceRevision: 1
    )
    state.record(delivered)
    state.prepareForReconnect(hasDeliveredFrame: true)

    var replay = delivered
    replay.stateSeq = 11
    replay.renderRevision = 2
    replay.scrollbackRows = 0
    replay.scrollbackSpans = []
    state.record(replay)
    #expect(!state.hydrationNeeded)

    var historyGrowth = replay
    historyGrowth.stateSeq = 12
    historyGrowth.renderRevision = 3
    historyGrowth.historyRows = 21
    historyGrowth.rowSpaceRevision = 2
    historyGrowth.scrollbackRows = 0
    historyGrowth.scrollbackSpans = []
    state.record(historyGrowth)

    #expect(!state.hydrationNeeded)
    #expect(!state.requiresHydration(for: historyGrowth))
}

/// Verifies an alternate-screen frame cannot satisfy primary scrollback
/// hydration when the mirror has no retained baseline.
@Test func alternateScreenFrameKeepsPrimaryHydrationPending() throws {
    var state = MobileTerminalMirrorState()
    let alternate = try MobileTerminalRenderGridFrame(
        surfaceID: "surface",
        stateSeq: 10,
        renderEpoch: "epoch-1",
        renderRevision: 1,
        columns: 80,
        rows: 4,
        full: true,
        rowSpans: [],
        activeScreen: .alternate,
        scrollbackRows: 0,
        anchor: .screen,
        historyRows: 20,
        rowSpaceRevision: 1
    )
    state.record(alternate)

    #expect(state.hydrationNeeded)
}

/// Verifies a viewport-anchored full frame cannot stand in for primary
/// scrollback hydration when it carries no history rows.
@Test func viewportFrameKeepsPrimaryHydrationPending() throws {
    var state = MobileTerminalMirrorState()
    let viewport = try MobileTerminalRenderGridFrame(
        surfaceID: "surface",
        stateSeq: 10,
        renderEpoch: "epoch-1",
        renderRevision: 1,
        columns: 80,
        rows: 4,
        full: true,
        rowSpans: [],
        scrollbackRows: 0,
        anchor: .viewport,
        historyRows: 20,
        rowSpaceRevision: 1
    )
    state.record(viewport)

    #expect(state.hydrationNeeded)
}
