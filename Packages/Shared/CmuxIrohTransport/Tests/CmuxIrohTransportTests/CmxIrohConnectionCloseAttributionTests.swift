import CMUXMobileCore
import Testing

@testable import CmuxIrohTransport

@Suite
struct CmxIrohConnectionCloseAttributionTests {
    @Test
    func classifiesRemoteApplicationCloseWithCode() {
        #expect(
            CmxIrohConnectionCloseAttribution.classify(
                "ConnectionLost(ApplicationClosed(ApplicationClose { error_code: 42, reason: \"closed by remote peer\" }))"
            ) == CmxIrohConnectionCloseAttribution(
                initiator: .remote,
                applicationErrorCode: 42,
                failureKind: .connectionClosed
            )
        )
    }

    @Test
    func classifiesLocalClose() {
        #expect(
            CmxIrohConnectionCloseAttribution.classify(
                "ConnectionLost(LocallyClosed)"
            ) == CmxIrohConnectionCloseAttribution(
                initiator: .local,
                applicationErrorCode: nil,
                failureKind: .cancelled
            )
        )
    }

    @Test
    func classifiesTransportIdleTimeout() {
        #expect(
            CmxIrohConnectionCloseAttribution.classify(
                "ConnectionLost(TimedOut)"
            ) == CmxIrohConnectionCloseAttribution(
                initiator: .timedOut,
                applicationErrorCode: nil,
                failureKind: .transportIdleTimedOut
            )
        )
    }

    @Test
    func applicationCloseReasonCannotSpoofLocalInitiator() {
        #expect(
            CmxIrohConnectionCloseAttribution.classify(
                "ConnectionLost(ApplicationClosed(ApplicationClose { error_code: 7, reason: \"local_service_unavailable\" }))"
            ) == CmxIrohConnectionCloseAttribution(
                initiator: .remote,
                applicationErrorCode: 7,
                failureKind: .connectionClosed
            )
        )
    }

    @Test
    func transportCryptoCodeIsNotAnApplicationErrorCode() {
        #expect(
            CmxIrohConnectionCloseAttribution.classify(
                "ConnectionLost(TransportError(Code::crypto(0x100)))"
            ) == CmxIrohConnectionCloseAttribution(
                initiator: .unknown,
                applicationErrorCode: nil,
                failureKind: .secureChannelFailed
            )
        )
    }

    @Test
    func authoritativeDriverCauseSupersedesTentativeLocalClose() async {
        let store = CmxIrohConnectionCloseAttributionStore()
        await store.recordTentative(CmxIrohConnectionCloseAttribution(
            initiator: .local,
            applicationErrorCode: 9,
            failureKind: .cancelled
        ))

        let authoritative = await store.recordAuthoritative(
            cause: "ConnectionLost(ApplicationClosed(ApplicationClose { error_code: 42 }))"
        )

        #expect(authoritative.initiator == .remote)
        #expect(authoritative.applicationErrorCode == 42)
        #expect(await store.current() == authoritative)
    }

    @Test
    func leavesUnrecognizedCauseBoundedAndUnknown() {
        #expect(
            CmxIrohConnectionCloseAttribution.classify(
                "opaque bridge failure without stable tokens"
            ) == CmxIrohConnectionCloseAttribution(
                initiator: .unknown,
                applicationErrorCode: nil,
                failureKind: .unknown
            )
        )
    }

    @Test
    func freeFormRemoteAndTimeoutWordsCannotSpoofCloseAttribution() {
        #expect(
            CmxIrohConnectionCloseAttribution.classify(
                "remote peer timed out while opaque adapter closed"
            ) == CmxIrohConnectionCloseAttribution(
                initiator: .unknown,
                applicationErrorCode: nil,
                failureKind: .unknown
            )
        )
    }
}
