import Foundation
import Testing
@testable import CMUXMobileCore

private func frame(hostTiming: MobileTerminalHostTiming? = nil) throws -> MobileTerminalRenderGridFrame {
    var frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 1,
        renderEpoch: "epoch-1",
        renderRevision: 1,
        columns: 8,
        rows: 2,
        full: true,
        clearedRows: [],
        rowSpans: [.init(row: 0, column: 0, text: "row")]
    )
    frame.hostTiming = hostTiming
    return frame
}

@Test func hostTimingRoundTripsOnTheFrame() throws {
    let timing = MobileTerminalHostTiming(
        inputReceivedMicros: 1_000,
        inputAcceptedMicros: 1_200,
        frameCapturedMicros: 5_000,
        frameDispatchedMicros: 5_400,
        pacer: MobileTerminalPacerSample(periodMillis: 90, emitted: 11, coalesced: 16, sheds: 0)
    )
    let data = try JSONEncoder().encode(try frame(hostTiming: timing))
    let decoded = try JSONDecoder().decode(MobileTerminalRenderGridFrame.self, from: data)
    #expect(decoded.hostTiming == timing)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"host_timing\""))
    #expect(json.contains("\"period_ms\":90"))
}

@Test func framesWithoutTimingDecodeAndOmitTheKey() throws {
    let data = try JSONEncoder().encode(try frame())
    let json = try #require(String(data: data, encoding: .utf8))
    // Most frames carry no timing; the key must not cost bytes on them.
    #expect(!json.contains("host_timing"))
    let decoded = try JSONDecoder().decode(MobileTerminalRenderGridFrame.self, from: data)
    #expect(decoded.hostTiming == nil)
}

@Test func completeInputStampsRequireOrderedMacPass() {
    var timing = MobileTerminalHostTiming(
        inputReceivedMicros: 10, inputAcceptedMicros: 20,
        frameCapturedMicros: 30, frameDispatchedMicros: 40
    )
    #expect(timing.hasCompleteInputStamps)
    timing.frameCapturedMicros = 15
    #expect(!timing.hasCompleteInputStamps)
    timing.frameCapturedMicros = nil
    #expect(!timing.hasCompleteInputStamps)
}

@Test func estimatorRoundTripIsExactWithoutClockSync() {
    var estimator = MobileTerminalClockOffsetEstimator()
    // Mac clock runs 5s ahead. Uplink 40ms, Mac work 10ms, downlink 60ms.
    let skew: UInt64 = 5_000_000_000
    let t1: UInt64 = 1_000_000_000
    let split = estimator.observe(
        phoneSendNanos: t1,
        macReceiveMicros: (t1 + skew + 40_000_000) / 1_000,
        macDispatchMicros: (t1 + skew + 50_000_000) / 1_000,
        phoneReceiveNanos: t1 + 110_000_000
    )
    #expect(split?.roundTripNanos == 100_000_000)
    #expect((split?.uplinkNanos ?? 0) + (split?.downlinkNanos ?? 0) == 100_000_000)
}

@Test func estimatorSplitsUsingTheQuickestExchangesOffset() {
    var estimator = MobileTerminalClockOffsetEstimator()
    let skew: UInt64 = 5_000_000_000
    // Quick, symmetric exchange: 20ms each way. Fixes the offset.
    var t1: UInt64 = 1_000_000_000
    _ = estimator.observe(
        phoneSendNanos: t1,
        macReceiveMicros: (t1 + skew + 20_000_000) / 1_000,
        macDispatchMicros: (t1 + skew + 30_000_000) / 1_000,
        phoneReceiveNanos: t1 + 50_000_000
    )
    // A later exchange whose uplink stalled for 900ms (radio wake-up).
    t1 = 2_000_000_000
    let stalled = estimator.observe(
        phoneSendNanos: t1,
        macReceiveMicros: (t1 + skew + 920_000_000) / 1_000,
        macDispatchMicros: (t1 + skew + 930_000_000) / 1_000,
        phoneReceiveNanos: t1 + 950_000_000
    )
    // The stall is attributed to the uplink, not smeared across both paths.
    #expect(stalled?.uplinkNanos == 920_000_000)
    #expect(stalled?.downlinkNanos == 20_000_000)
}

@Test func estimatorRejectsInconsistentTimestamps() {
    var estimator = MobileTerminalClockOffsetEstimator()
    // Mac work longer than the whole phone-observed exchange is impossible.
    #expect(estimator.observe(
        phoneSendNanos: 1_000_000_000,
        macReceiveMicros: 0,
        macDispatchMicros: 500_000,
        phoneReceiveNanos: 1_100_000_000
    ) == nil)
}
