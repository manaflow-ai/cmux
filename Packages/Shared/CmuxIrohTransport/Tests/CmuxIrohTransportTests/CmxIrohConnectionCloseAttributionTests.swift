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
}
