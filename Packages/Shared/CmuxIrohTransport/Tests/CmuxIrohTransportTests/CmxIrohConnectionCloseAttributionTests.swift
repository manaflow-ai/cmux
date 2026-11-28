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

    // The uniffi boundary returns quinn ConnectionError DISPLAY strings from
    // Connection.closed()/close_reason() ("timed out", "closed",
    // "closed by peer: ..."), not the Debug fragments matched above. Every
    // production close cause fell through to unknown/unknown until these
    // formats were recognized (https://github.com/manaflow-ai/cmux/issues/9169).

    @Test
    func classifiesDisplayIdleTimeout() {
        #expect(
            CmxIrohConnectionCloseAttribution.classify("timed out")
                == CmxIrohConnectionCloseAttribution(
                    initiator: .timedOut,
                    applicationErrorCode: nil,
                    failureKind: .transportIdleTimedOut
                )
        )
    }

    @Test
    func classifiesDisplayLocalClose() {
        #expect(
            CmxIrohConnectionCloseAttribution.classify("closed")
                == CmxIrohConnectionCloseAttribution(
                    initiator: .local,
                    applicationErrorCode: nil,
                    failureKind: .cancelled
                )
        )
    }

    @Test
    func classifiesDisplayPeerApplicationCloseWithBareCode() {
        #expect(
            CmxIrohConnectionCloseAttribution.classify("closed by peer: 42")
                == CmxIrohConnectionCloseAttribution(
                    initiator: .remote,
                    applicationErrorCode: 42,
                    failureKind: .connectionClosed
                )
        )
    }

    @Test
    func classifiesDisplayPeerApplicationCloseWithReasonAndCode() {
        #expect(
            CmxIrohConnectionCloseAttribution.classify(
                "closed by peer: going away (code 42)"
            ) == CmxIrohConnectionCloseAttribution(
                initiator: .remote,
                applicationErrorCode: 42,
                failureKind: .connectionClosed
            )
        )
    }

    @Test
    func classifiesWhitelistedServerReasonAndFailure() {
        let attribution = CmxIrohConnectionCloseAttribution.classify(
            "closed by peer: admission_lease_expired (code 42)"
        )
        #expect(attribution.remoteReason == .admissionLeaseExpired)
        #expect(attribution.failureKind == .admissionLeaseExpired)
        #expect(attribution.applicationErrorCode == 42)
    }

    @Test
    func ignoresLookalikeFreeFormCloseReason() {
        let attribution = CmxIrohConnectionCloseAttribution.classify(
            "closed by peer: admission_lease_expired_but_not_protocol (code 42)"
        )
        #expect(attribution.remoteReason == .unknown)
        #expect(attribution.failureKind == .connectionClosed)
    }

    @Test
    func classifiesDisplayPeerReset() {
        #expect(
            CmxIrohConnectionCloseAttribution.classify("reset by peer")
                == CmxIrohConnectionCloseAttribution(
                    initiator: .remote,
                    applicationErrorCode: nil,
                    failureKind: .connectionClosed
                )
        )
    }

    @Test
    func classifiesDisplayPeerTransportAbortWithoutStealingApplicationCode() {
        #expect(
            CmxIrohConnectionCloseAttribution.classify(
                "aborted by peer: CONNECTION_REFUSED: server busy"
            ) == CmxIrohConnectionCloseAttribution(
                initiator: .remote,
                applicationErrorCode: nil,
                failureKind: .connectionClosed
            )
        )
    }

    @Test
    func displayPeerReasonCannotSpoofInitiatorOrTimeoutKind() {
        #expect(
            CmxIrohConnectionCloseAttribution.classify(
                "closed by peer: timed out (code 7)"
            ) == CmxIrohConnectionCloseAttribution(
                initiator: .remote,
                applicationErrorCode: 7,
                failureKind: .connectionClosed
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
