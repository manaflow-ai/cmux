import CmuxMobileRPC
import Testing

@testable import CmuxMobileShell

@Suite struct MobileMacSleepResultTests {
    @Test func connectionClosedMapsToRequested() {
        #expect(macPowerSleepResult(forSendError: MobileShellConnectionError.connectionClosed) == .requested)
    }

    @Test func explicitRPCErrorMapsToRefused() {
        #expect(macPowerSleepResult(forSendError: MobileShellConnectionError.rpcError("sleep_failed", "nope")) == .refused)
    }

    @Test func timeoutAndDeliveryFailuresMapToFailed() {
        let failures: [MobileShellConnectionError] = [
            .requestTimedOut,
            .invalidResponse,
            .insecureManualRoute,
            .attachTicketExpired,
            .authorizationFailed("auth"),
            .accountMismatch("account"),
        ]
        for failure in failures {
            #expect(macPowerSleepResult(forSendError: failure) == .failed)
        }
    }
}
