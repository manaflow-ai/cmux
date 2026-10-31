import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// HQ #4884: which signed-out Cloud actions sign in and then run for a person.
@MainActor
struct CloudSignInRecoveryTests {
    @Test func onlyTheSignedOutReasonRecovers() {
        #expect(CloudHandlers.signInRecovers("cloudOpenDesktop", reason: CloudStrings.signInFirst))
        #expect(CloudHandlers.signInRecovers("newCloudWorkspace", reason: CloudStrings.signInFirst))
        #expect(!CloudHandlers.signInRecovers("cloudOpenDesktop", reason: CloudStrings.localBackend))
        #expect(!CloudHandlers.signInRecovers("cloudOpenDesktop", reason: CloudStrings.noMachine))
    }

    @Test func signOutAndTheTeamPickerNeverSignInFirst() {
        for id: ActionID in ["palette.auth.signOut", "openTeamPicker"] {
            #expect(!CloudHandlers.signInRecovers(id, reason: CloudStrings.signInFirst))
        }
    }

    @Test func theNoteSaysRunningSignsInFirst() {
        #expect(CloudStrings.signInToContinue != CloudStrings.signInFirst)
        #expect(!CloudStrings.signInToContinue.contains("command palette"))
    }
}
