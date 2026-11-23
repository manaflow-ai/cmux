@testable import CmuxMobileLive
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// The team invite toasts and the email alert's Send: a failure says why, a join names its team,
/// and Send waits for an address the service accepts.
@MainActor @Suite struct TeamInviteTextTests {
    @Test func sendWaitsForAnAddressShape() {
        #expect(InviteEmail.isPlausible("name@example.com"))
        #expect(InviteEmail.isPlausible("  a.b+c@mail.example.co.uk \n"))
        #expect(!InviteEmail.isPlausible(""))
        #expect(!InviteEmail.isPlausible("name"))
        #expect(!InviteEmail.isPlausible("name@"))
        #expect(!InviteEmail.isPlausible("@example.com"))
        #expect(!InviteEmail.isPlausible("name@example"))
        #expect(!InviteEmail.isPlausible("name@example."))
        #expect(!InviteEmail.isPlausible("a@b@example.com"))
        #expect(!InviteEmail.isPlausible("na me@example.com"))
        #expect(!InviteEmail.isPlausible(String(repeating: "a", count: 65) + "@example.com"))
    }

    @Test func aJoinNamesItsTeam() {
        #expect(ShellModel.joinedText(AppStore.AccountTeam(id: "t", name: "Design")) == "Joined Design")
        #expect(ShellModel.joinedText(nil) == "Joined the team")
    }

    @Test func aFailedJoinSaysWhy() {
        #expect(ShellModel.joinFailureText(URLError(.notConnectedToInternet)) == "You're offline. Try again when you're connected.")
        #expect(ShellModel.joinFailureText(URLError(.badServerResponse)) == "That invite link didn't work")
    }

    @Test func aFailedEmailInviteSaysWhy() {
        let limited = LiveAPI.Failure(status: 429, code: "rate_limited", message: "too many invitations")
        #expect(ShellModel.sendInviteFailureText(limited) == "Too many invitations. Try again in a minute.")
        let rejected = LiveAPI.Failure(status: 400, code: "bad_request", message: "email is required")
        #expect(ShellModel.sendInviteFailureText(rejected) == InviteEmail.invalidMessage)
        let refused = LiveAPI.Failure(status: 502, code: "invite_failed", message: "Stack refused")
        #expect(ShellModel.sendInviteFailureText(refused) == "Couldn't send the invitation")
        #expect(ShellModel.sendInviteFailureText(URLError(.notConnectedToInternet)) == "You're offline. Try again when you're connected.")
    }
}
