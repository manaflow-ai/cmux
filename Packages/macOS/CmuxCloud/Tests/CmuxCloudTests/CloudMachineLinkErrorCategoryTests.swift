@testable import CmuxCloud
import Testing

@Suite("Cloud machine link error categories")
struct CloudMachineLinkErrorCategoryTests {
    @Test("transport failures classify as daemon unavailable")
    func transportFailuresAreDaemonUnavailable() {
        #expect(CloudMachineLink.LinkError.timedOut.category == .daemonUnavailable)
        #expect(CloudMachineLink.LinkError.exited(status: 1, output: "daemon unavailable").category == .daemonUnavailable)
    }

    @Test("client and request failures retain their own categories")
    func nonDaemonFailuresDoNotUseDaemonCategory() {
        #expect(CloudMachineLink.LinkError.clientMissing.category == .clientUnavailable)
        #expect(CloudMachineLink.LinkError.spawnFailed("launch failed").category == .clientUnavailable)
        #expect(CloudMachineLink.LinkError.inputTooLarge.category == .requestRejected)
        #expect(CloudMachineLink.LinkError.failureMessage("daemon unavailable").category == .other)
    }

    @Test("link diagnostics redact the internal client name")
    func userFacingLinkCopyIsProductNeutral() {
        let errors: [CloudMachineLink.LinkError] = [
            .spawnFailed("cmux-tui: launch failed"),
            .exited(status: 1, output: "cmux-tui: route refused"),
            .failureMessage("cmux-tui rejected the request"),
        ]
        for error in errors {
            #expect(error.localizedDescription.contains("cmux-tui") == false)
        }
        #expect(CloudMachineLink.LinkError.spawnFailed("cmux-tui: launch failed").localizedDescription.contains("launch failed"))
        #expect(CloudMachineLink.LinkError.exited(status: 1, output: "cmux-tui: route refused").localizedDescription.contains("route refused"))
    }
}
