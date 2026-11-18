import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemonService
import Testing

/// HQ #4884: which signed-out Cloud actions sign in and then run for a person.
@MainActor
struct CloudSignInRecoveryTests {
    @Test func onlyTheSignedOutReasonRecovers() {
        #expect(CloudSignInRecovery.recovers("cloudOpenDesktop", reason: CloudStrings.signInFirst))
        #expect(CloudSignInRecovery.recovers("newCloudWorkspace", reason: CloudStrings.signInFirst))
        #expect(!CloudSignInRecovery.recovers("cloudOpenDesktop", reason: CloudStrings.localBackend))
        #expect(!CloudSignInRecovery.recovers("cloudOpenDesktop", reason: CloudStrings.noMachine))
    }

    @Test func signOutAndTheTeamPickerNeverSignInFirst() {
        for id: ActionID in ["palette.auth.signOut", "openTeamPicker"] {
            #expect(!CloudSignInRecovery.recovers(id, reason: CloudStrings.signInFirst))
        }
    }

    @Test func theNoteSaysRunningSignsInFirst() {
        #expect(CloudStrings.signInToContinue != CloudStrings.signInFirst)
        #expect(!CloudStrings.signInToContinue.contains("command palette"))
    }

    @Test func signedInReplayCollectsMissingSubjectBeforeRunning() {
        let registry = ActionRegistry.standard()
        var collected: ActionID?, ran = false
        registry.bind("cloudOpenDesktop", invoke: { _ in ran = true })
        registry.argumentCollector = { id, invocation in
            collected = id
            #expect(invocation.target == nil)
        }
        CloudSignInRecovery.resume("cloudOpenDesktop", ActionInvocation(), in: registry)
        #expect(collected == "cloudOpenDesktop")
        #expect(!ran)
        CloudSignInRecovery.resume("cloudOpenDesktop", ActionInvocation(target: ActionTargetRef(kind: .machine, id: "chosen")), in: registry)
        #expect(ran)
    }
}
