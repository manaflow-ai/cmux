import Foundation
import Testing
@testable import CMUXMobileCore

/// Limits and shapes outside their documented ranges used to trap in a
/// precondition; each now refuses or takes a safe value.
@Suite struct OutOfRangeLimitTests {
    @Test func decodeFramesRefusesLimitsBelowTheirMinimum() throws {
        var buffer = try MobileSyncFrameCodec.encodeFrame(Data("x".utf8))
        #expect(throws: MobileSyncFrameCodecError.self) {
            try MobileSyncFrameCodec.decodeFrames(from: &buffer, maximumDecodedFrameCount: 0)
        }
        #expect(throws: MobileSyncFrameCodecError.self) {
            try MobileSyncFrameCodec.decodeFrames(from: &buffer, maximumFrameByteCount: -1)
        }
        #expect(try MobileSyncFrameCodec.decodeFrames(from: &buffer) == [Data("x".utf8)])
    }

    @Test func frameSizeBudgetBelowOneByteBecomesOneByte() {
        let budget = MobileBrowserFrameSizeBudget(maximumBase64Bytes: 0)
        #expect(budget.maximumBase64Bytes == 1)
        #expect(!budget.contains(encodedByteCount: 1))
        #expect(budget.downscaleFactor(encodedByteCount: 1).isFinite)
    }

    @Test func streamPacingOutOfRangeValuesTakeTheirDefaults() {
        let pacing = MobileBrowserStreamPacing(
            maximumUnackedFrames: 0,
            minimumFrameInterval: -1,
            settleDelay: .nan,
            ackStallTimeout: 0
        )
        #expect(pacing == MobileBrowserStreamPacing())
    }

    @Test func rpcWorkQuotaBelowOneBecomesOne() {
        let quota = MobileHostRPCWorkQuota(maximumConcurrentRequestCount: 0, maximumAggregateFrameByteCount: -5)
        #expect(quota.maximumConcurrentRequestCount == 1)
        #expect(quota.maximumAggregateFrameByteCount == 1)
        #expect(quota.allowsAdmission(frameByteCount: 1, activeFrameByteCounts: [Int]()))
        #expect(!quota.allowsAdmission(frameByteCount: 1, activeFrameByteCounts: [0]))
    }

    @Test func credentialedSessionAcceptsAZeroResponseLimit() {
        _ = CmxCredentialedHTTPSession(maximumResponseByteCount: 0)
    }

    @Test func emissionStateTakesItsRowsFromTheSignatures() {
        let state = MobileTerminalRenderGridEmissionState(
            columns: -1,
            rows: 3,
            stateSeq: 0,
            activeScreen: .primary,
            rowSignatures: ["a"]
        )
        #expect(state.columns == 0)
        #expect(state.rows == 1)
    }

    /// The built-in Tailscale profile skips validation; its literal must pass it.
    @Test func builtInTailscaleProfilePassesValidation() throws {
        let key = CmxIrohNetworkProfileKey.activeTailscaleTunnel
        #expect(try CmxIrohNetworkProfileKey(source: key.source, profileID: key.profileID) == key)
        #expect(key.source == .tailscale)
    }
}
