import AppKit
import CmuxCloud
import CmuxSettingsUI
import Foundation

/// Invitations addressed to the signed-in user: the Settings card, the Cloud
/// header's team menu, the notification center, the socket and the CLI all
/// read `receivedInvitations` and join through `cloudAcceptInvitation`.
extension HostAccountFlow {
    /// Between polls while signed in. A new invitation also arrives by email,
    /// so the poll only needs to notice it within a few minutes.
    static let receivedInvitationsPollInterval: Duration = .seconds(300)
    private static let notifiedInvitationIDsKey = "cmux.team.invitations.notified"

    /// Starts the poll on sign-in and stops it on sign-out. Called from the
    /// coordinator observation, so it runs whenever auth state changes.
    func syncReceivedInvitationsPolling() {
        if isAuthenticated {
            guard receivedInvitationsPoll == nil else { return }
            receivedInvitationsPoll = Task { @MainActor [weak self] in
                await self?.refreshReceivedInvitations(notify: true)
                while !Task.isCancelled {
                    do {
                        try await ContinuousClock().sleep(for: Self.receivedInvitationsPollInterval)
                    } catch {
                        return
                    }
                    await self?.refreshReceivedInvitations(notify: true)
                }
            }
        } else {
            receivedInvitationsPoll?.cancel()
            receivedInvitationsPoll = nil
            receivedInvitations = []
            receivedInvitationsLoaded = false
        }
    }

    /// Re-reads the list. A failure keeps the last list; the caller that
    /// needs the error uses `cloudReceivedInvitations`.
    func refreshReceivedInvitations(notify: Bool) async {
        guard isAuthenticated else { return }
        do {
            let fresh = try await TeamsClient.shared.receivedInvitations()
            let previous = receivedInvitations
            receivedInvitations = fresh
            receivedInvitationsLoaded = true
            if notify { notifyNewInvitations(fresh, previous: previous) }
        } catch {
            // Offline or signed-out mid-flight: the next poll or action retries.
        }
    }

    /// A fresh read for the socket and CLI.
    func cloudReceivedInvitations() async throws -> [CloudReceivedInvitation] {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        let fresh = try await TeamsClient.shared.receivedInvitations()
        receivedInvitations = fresh
        receivedInvitationsLoaded = true
        return fresh
    }

    /// Joins the team, refreshes membership so the picker lists it, and makes
    /// it the active team. Returns the joined team id.
    @discardableResult
    func cloudAcceptInvitation(invitationID: String) async throws -> String {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        let result = try await TeamsClient.shared.acceptInvitation(invitationID: invitationID)
        receivedInvitations.removeAll { $0.id == invitationID }
        await coordinator.refreshTeams()
        try? await selectTeam(id: result.teamId)
        await refreshReceivedInvitations(notify: false)
        return result.teamId
    }

    func cloudDeclineInvitation(invitationID: String) async throws {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        try await TeamsClient.shared.declineInvitation(invitationID: invitationID)
        receivedInvitations.removeAll { $0.id == invitationID }
        await refreshReceivedInvitations(notify: false)
    }

    /// One notification per invitation id, remembered across launches so a
    /// restart does not repeat it. Ids the user already saw in a list are
    /// also skipped: the first load after sign-in notifies only when the
    /// list changed since the last notification.
    private func notifyNewInvitations(_ fresh: [CloudReceivedInvitation], previous: [CloudReceivedInvitation]) {
        let defaults = UserDefaults.standard
        var notified = Set(defaults.stringArray(forKey: Self.notifiedInvitationIDsKey) ?? [])
        let new = fresh.filter { !notified.contains($0.id) }
        guard !new.isEmpty,
              let tabId = AppDelegate.shared?.activeTabManagerForCommands(preferredWindow: nil)?.selectedTabId else {
            return
        }
        for invitation in new {
            let inviter = invitation.invitedBy
                ?? String(localized: "notification.teamInvite.someone", defaultValue: "A teammate")
            TerminalNotificationStore.shared.addNotification(
                tabId: tabId,
                surfaceId: nil,
                title: String(
                    format: String(localized: "notification.teamInvite.title", defaultValue: "%1$@ invited you to %2$@"),
                    inviter,
                    invitation.teamName
                ),
                subtitle: String(localized: "notification.teamInvite.subtitle", defaultValue: "cmux Cloud team"),
                body: String(
                    localized: "notification.teamInvite.body",
                    defaultValue: "Join from the team menu in the Cloud panel or Settings › Account."
                ),
                cooldownKey: "team-invite.\(invitation.id)",
                cooldownInterval: 3600
            )
            notified.insert(invitation.id)
        }
        // Keep the set bounded to the ids that can still matter.
        let live = Set(fresh.map(\.id))
        defaults.set(Array(notified.filter { live.contains($0) }.union(new.map(\.id))), forKey: Self.notifiedInvitationIDsKey)
    }
}

// MARK: - Settings Invitations card (AccountTeamManagement)

extension HostAccountFlow {
    func loadReceivedInvitations() async throws -> [AccountReceivedInvitation] {
        try await cloudReceivedInvitations().map(Self.accountReceivedInvitation)
    }

    func acceptReceivedInvitation(id: String) async throws {
        try await cloudAcceptInvitation(invitationID: id)
    }

    func declineReceivedInvitation(id: String) async throws {
        try await cloudDeclineInvitation(invitationID: id)
    }

    static func accountReceivedInvitation(_ invitation: CloudReceivedInvitation) -> AccountReceivedInvitation {
        AccountReceivedInvitation(
            id: invitation.id,
            teamID: invitation.teamId,
            teamName: invitation.teamName,
            invitedBy: invitation.invitedBy,
            role: invitation.role == .admin ? .admin : .member,
            expiresAt: invitation.expiresAt
        )
    }
}
