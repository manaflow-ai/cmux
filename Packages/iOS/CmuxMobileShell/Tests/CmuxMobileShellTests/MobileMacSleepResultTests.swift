import CmuxMobileRPC
import Testing

@testable import CmuxMobileShell

@Suite struct MobileMacSleepResultTests {
    @Test func explicitRPCErrorMapsToRefused() {
        let classifier = MobileMacSleepErrorClassifier()
        #expect(classifier.result(forSendError: MobileShellConnectionError.rpcError("sleep_failed", "nope")) == .refused)
    }

    @Test func timeoutAndDeliveryFailuresMapToFailed() {
        let classifier = MobileMacSleepErrorClassifier()
        let failures: [MobileShellConnectionError] = [
            .requestTimedOut,
            .connectionClosed,
            .invalidResponse,
            .insecureManualRoute,
            .attachTicketExpired,
            .authorizationFailed("auth"),
            .accountMismatch("account"),
        ]
        for failure in failures {
            #expect(classifier.result(forSendError: failure) == .failed)
        }
    }
}
