import Foundation
import Observation
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AccountTeamCardModelTests {
    @Test func roleChangesImmediatelyAndStaysSelectedUntilRefreshFinishes() async {
        let flow = TeamCardFlow()
        let model = AccountTeamCardModel(flow: flow)
        model.detail = flow.roster

        model.setRole(.admin, for: flow.member)

        #expect(model.detail?.members.last?.role == .admin)
        #expect(model.pendingID == flow.member.id)
        await waitUntil { flow.roleReply != nil }
        flow.finishRoleChange()
        await waitUntil { flow.detailReply != nil }
        #expect(model.detail?.members.last?.role == .admin)
        flow.finishReload(role: .admin)
        await waitUntil { !model.isLoading }
        #expect(model.detail?.members.last?.role == .admin)
        #expect(model.pendingID == nil)
        #expect(model.errorMessage == nil)
    }

    @Test func failedSaveRollsBackRoleAndShowsError() async {
        let flow = TeamCardFlow()
        let model = AccountTeamCardModel(flow: flow)
        model.detail = flow.roster
        model.setRole(.admin, for: flow.member)
        #expect(model.detail?.members.last?.role == .admin)
        await waitUntil { flow.roleReply != nil }

        flow.finishRoleChange(error: TeamCardFailure.rejected)

        await waitUntil { model.pendingID == nil }
        #expect(model.detail?.members.last?.role == .member)
        #expect(model.errorMessage == "Save failed")
        #expect(!model.isLoading)
    }

    @Test func aSecondSelectionCannotReplaceTheInFlightRole() async {
        let flow = TeamCardFlow()
        let model = AccountTeamCardModel(flow: flow)
        model.detail = flow.roster
        model.setRole(.admin, for: flow.member)
        model.setRole(.member, for: flow.member)
        #expect(model.detail?.members.last?.role == .admin)
        await waitUntil { flow.roleReply != nil }
        #expect(flow.roleRequests == [.admin])
        flow.finishRoleChange(error: TeamCardFailure.rejected)
        await waitUntil { model.pendingID == nil }
    }

    @Test func oldTeamsFailedSaveDoesNotChangeNewTeamsRosterOrError() async {
        let flow = TeamCardFlow()
        let model = AccountTeamCardModel(flow: flow)
        model.detail = flow.roster
        model.setRole(.admin, for: flow.member)
        await waitUntil { flow.roleReply != nil }
        flow.selectedTeamID = "other-team"
        model.detail = flow.makeRoster(role: .admin)

        flow.finishRoleChange(error: TeamCardFailure.rejected)

        await waitUntil { model.pendingID == nil }
        #expect(model.detail?.teamID == "other-team")
        #expect(model.detail?.members.last?.role == .admin)
        #expect(model.errorMessage == nil)
    }

    @Test func rosterWaitsForSignInToSettleBeforeLoading() async {
        let flow = TeamCardFlow()
        flow.isWorkingOnAuth = true
        let model = AccountTeamCardModel(flow: flow)

        // Sign-in publishes the team before its token handoff finishes. A
        // fetch in that window is refused locally and used to leave
        // "cmux Cloud is unreachable" on the card.
        model.reload()

        #expect(flow.detailRequests == 0)
        #expect(model.isLoading)
        #expect(model.errorMessage == nil)

        flow.isWorkingOnAuth = false
        model.reloadIfNeeded()

        await waitUntil { flow.detailReply != nil }
        #expect(flow.detailRequests == 1)
        flow.finishReload(role: .member)
        await waitUntil { !model.isLoading }
        #expect(model.detail?.teamID == "team")
        #expect(model.errorMessage == nil)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        while !predicate() {
            let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            withObservationTracking {
                _ = predicate()
            } onChange: {
                continuation.yield(())
                continuation.finish()
            }
            // Observation fires before the write. Resuming on the main actor
            // reads the new value after that write has completed.
            var iterator = changes.makeAsyncIterator()
            guard await iterator.next() != nil else {
                Issue.record("Team card observation ended before the expected state")
                return
            }
        }
    }
}

private enum TeamCardFailure: Error { case rejected }

@MainActor
@Observable
private final class TeamCardFlow: AccountFlow {
    var currentIdentity: AccountIdentity? { nil }
    var availableTeams: [AccountTeamSummary] { [] }
    var selectedTeamID: String? = "team"
    var isWorkingOnAuth = false
    var signInIsSlow: Bool { false }
    var isProUpgradeAvailable: Bool { false }
    var isProActive: Bool { false }
    var canManageBilling: Bool { false }
    var supportsTeamManagement: Bool { true }
    var roleReply: CheckedContinuation<Void, any Error>?
    var detailReply: CheckedContinuation<AccountTeamDetail, any Error>?
    var roleRequests: [AccountTeamRole] = []
    var detailRequests = 0

    var member: AccountTeamMember { roster.members[1] }
    var roster: AccountTeamDetail { makeRoster(role: .member) }

    func makeRoster(role: AccountTeamRole) -> AccountTeamDetail {
        AccountTeamDetail(
            teamID: selectedTeamID!, teamName: "Test team", viewerUserID: "viewer",
            viewerRole: .admin, canInvite: true, canRemoveMembers: true,
            members: [
                AccountTeamMember(userID: "viewer", displayName: "Viewer", email: nil, role: .admin, isViewer: true),
                AccountTeamMember(userID: "member", displayName: "Member", email: nil, role: role, isViewer: false),
            ],
            invitations: [], links: [], memberLimit: nil
        )
    }

    func changeTeamMemberRole(userID: String, role: AccountTeamRole) async throws {
        roleRequests.append(role)
        try await withCheckedThrowingContinuation { roleReply = $0 }
    }

    func loadTeamDetail() async throws -> AccountTeamDetail {
        detailRequests += 1
        return try await withCheckedThrowingContinuation { detailReply = $0 }
    }

    func finishRoleChange(error: (any Error)? = nil) {
        let reply = roleReply
        roleReply = nil
        if let error { reply?.resume(throwing: error) }
        else { reply?.resume() }
    }

    func finishReload(role: AccountTeamRole) {
        let reply = detailReply
        detailReply = nil
        reply?.resume(returning: makeRoster(role: role))
    }

    func teamManagementMessage(for error: any Error) -> String { "Save failed" }
    func selectTeam(id: String?) async throws { selectedTeamID = id }
    func startSignIn() {}
    func openSignInInDefaultBrowser() {}
    func signOut() async {}
    func refreshCurrentUser() async {}
    func openProUpgrade() {}
    func refreshBillingPlan() async {}
    func openBillingPortal() {}
}
