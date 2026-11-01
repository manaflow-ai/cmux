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

    /// The restart checks the guest kind the transfer installed on: an owner guest, or with the DEV
    /// creator allowance a team guest as well.
    @Test func restartAcceptsTheCreatorsTeamGuestOnlyWithTheAllowance() async throws {
        var commands: [String] = []
        let ok = #"{"restarted":1,"after_turn":0,"failed":0,"errors":[]}"#
        _ = try await CloudPresenter.restartCredentialSession("chat-1", exec: { command in
            commands.append(command); return CloudExecResult(exitCode: 0, stdout: ok, stderr: "")
        })
        _ = try await CloudPresenter.restartCredentialSession("chat-1", creatorTeamGuest: true, exec: { command in
            commands.append(command); return CloudExecResult(exitCode: 0, stdout: ok, stderr: "")
        })
        #expect(commands[0].contains("in owner)") && !commands[0].contains("team"))
        #expect(commands[1].contains("in owner|team)"))
    }

    @Test func credentialRecoveryConfirmationIsAlwaysUserOnly() {
        #expect(DebugDialog.userOnly.contains(CloudPresenter.credentialRecoveryIdentifier))
        #expect(DebugDialog.userOnly.contains(CloudPresenter.codexDeviceCodeIdentifier))
        // cloud.startChat's first-login confirm caches and installs a year-long login: only the person says Set Up.
        #expect(DebugDialog.userOnly.contains(CloudPresenter.firstLoginIdentifier))
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
