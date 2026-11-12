@testable import CmuxCloud
import Testing

@Suite("Cloud machine link error categories")
struct CloudMachineLinkErrorCategoryTests {
    @Test("transport failures classify as daemon unavailable")
    func transportFailuresAreDaemonUnavailable() {
        #expect(CloudMachineLink.LinkError.timedOut.category == .daemonUnavailable)
        #expect(CloudMachineLink.LinkError.exited(status: 1, output: "daemon unavailable").category == .daemonUnavailable)
        #expect(CloudMachineLink.LinkError.exited(status: 1, output: #"{"code":"transport.closed"}"#).category == .daemonUnavailable)
        #expect(CloudMachineLink.LinkError.exited(status: 1, output: #"{"code":"transport.timeout"}"#).category == .daemonUnavailable)
        #expect(CloudMachineLink.LinkError.exited(
            status: 1,
            output: #"{"code":"raw.command_failed","details":{"error":"transport.closed"}}"#
        ).category == .daemonUnavailable)
    }

    @Test("client and request failures retain their own categories")
    func nonDaemonFailuresDoNotUseDaemonCategory() {
        #expect(CloudMachineLink.LinkError.clientMissing.category == .clientUnavailable)
        #expect(CloudMachineLink.LinkError.spawnFailed("launch failed").category == .clientUnavailable)
        #expect(CloudMachineLink.LinkError.exitedBeforeSocket(status: 2, output: "unknown flag").category == .clientUnavailable)
        #expect(CloudMachineLink.LinkError.inputTooLarge.category == .requestRejected)
        #expect(CloudMachineLink.LinkError.failureMessage("daemon unavailable").category == .other)
        #expect(CloudMachineLink.LinkError.exited(status: 1, output: #"{"code":"revision.conflict"}"#).category == .other)
        #expect(CloudMachineLink.LinkError.exited(status: 1, output: "{}").category == .other)
    }

    @Test("link diagnostics redact the internal client name")
    func userFacingLinkCopyIsProductNeutral() {
        let errors: [CloudMachineLink.LinkError] = [
            .spawnFailed("cmux-tui: launch failed"),
            .exited(status: 1, output: "cmux-tui: route refused"),
            .exitedBeforeSocket(status: 2, output: "cmux-tui: unknown flag"),
            .failureMessage("cmux-tui rejected the request"),
        ]
        for error in errors {
            #expect(error.localizedDescription.contains("cmux-tui") == false)
        }
        #expect(CloudMachineLink.LinkError.spawnFailed("cmux-tui: launch failed").localizedDescription.contains("launch failed"))
        #expect(CloudMachineLink.LinkError.exited(status: 1, output: "cmux-tui: route refused").localizedDescription.contains("route refused"))
        #expect(CloudMachineLink.LinkError.clientMissing.localizedDescription.contains("CMUX_TUI_CLIENT") == false)
    }
}
