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
