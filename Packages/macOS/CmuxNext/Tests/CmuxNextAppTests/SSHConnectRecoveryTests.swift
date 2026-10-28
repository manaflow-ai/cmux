import CmuxNextDesign
import CmuxNextRemote
@testable import CmuxNextApp
import Testing

@MainActor struct SSHConnectRecoveryTests {
    @Test func networkAndDaemonFailuresOfferRecovery() {
        for status: SSHConnectionMachine.Status in [.unreachable("nohost.invalid"), .failed("daemon exited"),
                                                   .authFailed("denied"), .hostKeyUntrusted("changed"), .installFailed("download failed")] {
            #expect(SSHConnectRecovery.isFailure(status))
        }
        for status: SSHConnectionMachine.Status in [.connecting, .connected, .reconnecting, .installing, .offline] {
            #expect(!SSHConnectRecovery.isFailure(status))
        }
    }

    @Test func failureOffersRetryDiagnosticsAndFullErrorCopy() {
        let spec = SSHConnectRecovery.spec(name: "nohost.invalid", detail: "Could not resolve hostname")
        #expect(spec.lines == ["Could not resolve hostname"])
        #expect(spec.buttons.map(\.id) == ["cancel", "copy", "check", "retry"])
        #expect(spec.defaultButton?.id == "retry")
        #expect(spec.cancelButton?.id == "cancel")
    }
}
