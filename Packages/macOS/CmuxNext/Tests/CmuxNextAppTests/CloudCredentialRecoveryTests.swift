import CmuxNextAgentPane
import CmuxNextCloud
@testable import CmuxNextApp
import Foundation
import Testing

@MainActor
struct CloudCredentialRecoveryTests {
    /// cmux-platform#89: a Worker machine (the app server link) reaches its exec and file routes on
    /// the Worker machines origin, so recovery is on there too once signed in.
    @Test func credentialRecoveryAvailabilityReturnsAfterSignInOnEitherLink() {
        #expect(!AgentTabStore.cloudCredentialTransferIsAvailable(linkSource: .legacy, isSignedIn: false))
        #expect(AgentTabStore.cloudCredentialTransferIsAvailable(linkSource: .legacy, isSignedIn: true))
        #expect(AgentTabStore.cloudCredentialTransferIsAvailable(linkSource: .appServer, isSignedIn: true))
        #expect(!AgentTabStore.cloudCredentialTransferIsAvailable(linkSource: .appServer, isSignedIn: false))
    }

    @Test func restartMustFinishBeforeRetryAndNeverExposesProviderErrors() async throws {
        for (reply, accepted) in [
            (#"{"restarted":1,"after_turn":0,"failed":0,"errors":[]}"#, true),
            (#"{"restarted":0,"after_turn":0,"failed":0,"errors":[]}"#, true),
            (#"{"restarted":0,"after_turn":1,"failed":0,"errors":[]}"#, false),
            (#"{"restarted":0,"after_turn":0,"failed":1,"errors":[{"error":"private diagnostic"}]}"#, false),
            (#"{"restarted":1}"#, false), ("invalid", false),
        ] {
            let recovered = try await CloudPresenter.restartCredentialSession("chat-1", exec: { command in
                #expect(command.contains("acp --json session restart chat-1"))
                return CloudExecResult(exitCode: 0, stdout: reply, stderr: "private diagnostic")
            })
            #expect(recovered == accepted)
        }
        #expect(try await !CloudPresenter.restartCredentialSession("chat-1", exec: { _ in
            CloudExecResult(exitCode: 1, stdout: #"{"restarted":1,"after_turn":0,"failed":0}"#, stderr: "")
        }))
    }

    @Test func credentialRecoveryConfirmationIsAlwaysUserOnly() {
        #expect(DebugDialog.userOnly.contains(CloudPresenter.credentialRecoveryIdentifier))
        #expect(DebugDialog.userOnly.contains(CloudPresenter.codexDeviceCodeIdentifier))
    }

    @Test func remoteHandshakeCarriesProviderVMIdentitySeparatelyFromSession() async throws {
        var host = AgentTabRemoteHost(surface: 7, session: "chat-1", machine: "Workspace", hostID: "Workspace",
                                      endpoint: { throw CancellationError() })
        #expect(try await host.handshake(sessionId: nil).cloudMachineID == nil)
        host.cloudMachineID = "provider-vm-1"
        let handshake = try await host.handshake(sessionId: nil)
        let reply = AgentPaneReply.handshake(handshake)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["cloudMachineID"] as? String == "provider-vm-1")
        #expect(value["sessionId"] as? String == "chat-1")
        #expect(value["cloudCredentialRecoveryAvailable"] as? Bool == false)
        host.cloudCredentialRecoveryAvailable = true
        let enabled = AgentPaneReply.handshake(try await host.handshake(sessionId: nil))
        #expect((enabled["value"] as? [String: Any])?["cloudCredentialRecoveryAvailable"] as? Bool == true)
    }
}
