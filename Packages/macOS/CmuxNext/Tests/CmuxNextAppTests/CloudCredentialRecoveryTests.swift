import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

@MainActor
struct CloudCredentialRecoveryTests {
    @Test func remoteHandshakeCarriesProviderVMIdentitySeparatelyFromSession() async throws {
        var host = AgentTabRemoteHost(surface: 7, session: "chat-1", machine: "Workspace",
                                      endpoint: { throw CancellationError() })
        #expect(try await host.handshake(sessionId: nil).cloudMachineID == nil)
        host.cloudMachineID = "provider-vm-1"
        let handshake = try await host.handshake(sessionId: nil)
        let reply = AgentPaneReply.handshake(handshake)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["cloudMachineID"] as? String == "provider-vm-1")
        #expect(value["sessionId"] as? String == "chat-1")
    }
}
