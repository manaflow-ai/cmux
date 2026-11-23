import CmuxMobileModel
import Foundation
@testable import CmuxMobileAuth
import Testing

/// Joining by invite link says why it failed: Stack's known-error codes (the ones the web's accept
/// page reads) and the SDK's `network_error` map to their sentences; anything else keeps the caller's.
@MainActor @Suite struct TeamInviteFailureTests {
    @Test func stackCodesMapToTheirSentences() {
        #expect(TeamInviteFailure(code: "VERIFICATION_CODE_EXPIRED") == .expired)
        #expect(TeamInviteFailure(code: "VERIFICATION_CODE_ALREADY_USED") == .expired)
        #expect(TeamInviteFailure(code: "TEAM_INVITATION_EMAIL_MISMATCH") == .otherEmail)
        #expect(TeamInviteFailure(code: "TEAM_MEMBERSHIP_ALREADY_EXISTS") == .alreadyMember)
        #expect(TeamInviteFailure(code: "network_error") == .offline)
        #expect(TeamInviteFailure(code: "VERIFICATION_CODE_NOT_FOUND") == .other)
        #expect(TeamInviteFailure(code: "http_error") == .other)
    }

    @Test func messagesAndFallback() {
        #expect(TeamInviteFailure.expired.message(fallback: "x") == "This invite expired. Ask for a new one.")
        #expect(TeamInviteFailure.otherEmail.message(fallback: "x") == "This invite is for another email.")
        #expect(TeamInviteFailure.offline.message(fallback: "x") == "You're offline. Try again when you're connected.")
        #expect(TeamInviteFailure.alreadyMember.message(fallback: "x") == "You're already on this team.")
        #expect(TeamInviteFailure.other.message(fallback: "That invite link didn't work") == "That invite link didn't work")
    }

    @Test func transportErrorsReadAsOfflineOnlyWhenOffline() {
        #expect(TeamInviteFailure(URLError(.notConnectedToInternet)) == .offline)
        #expect(TeamInviteFailure(URLError(.networkConnectionLost)) == .offline)
        #expect(TeamInviteFailure(URLError(.badServerResponse)) == .other)
        #if os(iOS)
        #expect(TeamInviteFailure(CmuxMobileAuthModel.InviteError.requestFailed) == .other)
        #endif
        #expect(TeamInviteFailure(TeamInviteFailure.expired) == .expired)
    }

    // CmuxMobileAuthModel is iOS-only; `swift test` on macOS builds this suite without it.
    #if os(iOS)
    @Test func theJoinedTeamIsTheOneTheListGained() {
        let a = AppStore.AccountTeam(id: "a", name: "Alpha"), b = AppStore.AccountTeam(id: "b", name: "Beta")
        #expect(CmuxMobileAuthModel.joinedTeam(before: ["a"], after: [a, b]) == b)
        #expect(CmuxMobileAuthModel.joinedTeam(before: ["a", "b"], after: [a, b]) == nil)
    }
    #endif
}
