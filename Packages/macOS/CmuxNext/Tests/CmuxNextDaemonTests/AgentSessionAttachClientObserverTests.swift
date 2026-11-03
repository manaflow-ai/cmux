import Foundation
import Testing
@testable import CmuxNextDaemon

@Suite struct AgentSessionAttachClientObserverTests {
    @Test func observeUsesItsOwnCapabilityAndCommand() {
        let mode = AgentSessionAttachClient.Mode.observe
        #expect(mode.capability == DaemonCapability.agentSessionObserve.rawValue)
        #expect(mode.command == "agent-session-observe")
        #expect(mode.capability != DaemonCapability.agentSessionAttach.rawValue)
        #expect(mode.unsupportedMessage == "the daemon does not serve agent session observation")
        #expect(AgentSessionAttachClient.Mode.attach.unsupportedMessage == "the daemon does not serve agent session attach")
    }

    @Test func observeCannotStartAWritableChat() async {
        let client = AgentSessionAttachClient(surface: 7, mode: .observe) {
            throw CancellationError()
        }
        await #expect(throws: AgentSessionAttachError(code: AgentSessionAttachClient.startUnsupported,
                                                       message: "a read-only agent session cannot start a chat")) {
            _ = try await client.start(cwd: "/tmp", harness: nil)
        }
    }
}
