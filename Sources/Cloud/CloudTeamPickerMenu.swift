import AppKit
import CmuxSettingsUI

/// Builds the Cloud header's team pull-down from one snapshot of account state.
///
/// Rows are native menu items, so team names are never clipped to a fixed
/// width and the active team carries the standard checkmark. While a switch or
/// a team create is pending, a status row says so and every action is
/// disabled, so a second request cannot race the first. A pending create shows
/// its team, checked, until the server answers.
@MainActor
enum CloudTeamPickerMenu {
    static let switchingStatusIdentifier = "CloudTeamPickerSwitchingStatus"
    static let creatingStatusIdentifier = "CloudTeamPickerCreatingStatus"
    static let loadingTeamsIdentifier = "CloudTeamPickerLoadingTeams"
    static let pendingTeamIdentifier = "CloudTeamPickerPendingTeam"
    static let createTeamIdentifier = "CloudTeamPickerCreateTeamButton"
    static let invitedHeaderIdentifier = "CloudTeamPickerInvitedHeader"

    static func invitationIdentifier(_ invitationID: String) -> String {
        "CloudTeamPickerInvitation_\(invitationID)"
    }

    /// One invitation the signed-in user received, as the menu shows it.
    struct Invitation: Equatable, Sendable {
        let id: String
        let teamName: String
    }

    static func teamIdentifier(_ teamID: String) -> String {
        "CloudTeamPickerTeam_\(teamID)"
    }

    static func make(
        teams: [AccountTeamSummary],
        selectedTeamID: String?,
        isSwitching: Bool,
        pendingCreate: PendingTeamCreate?,
        onSelect: @escaping (AccountTeamSummary) -> Void,
        onCreate: @escaping () -> Void,
        onInvite: (() -> Void)? = nil,
        onMembers: (() -> Void)? = nil,
        invitations: [Invitation] = [],
        onJoin: ((Invitation) -> Void)? = nil
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if isSwitching {
            menu.addItem(statusItem(
                String(localized: "cloud.teamPicker.switching", defaultValue: "Switching teams…"),
                identifier: switchingStatusIdentifier
            ))
        }
        if pendingCreate != nil {
            menu.addItem(statusItem(
                String(localized: "cloud.teamPicker.creating", defaultValue: "Creating team…"),
                identifier: creatingStatusIdentifier
            ))
        }
        let isBusy = isSwitching || pendingCreate != nil
        if isBusy {
            menu.addItem(.separator())
        }
        // Until the create returns, the pending row stands for the new team,
        // which the coordinator may already list.
        let listedTeams = pendingCreate.map { pending in
            teams.filter { pending.existingTeamIDs.contains($0.id) }
        } ?? teams
        if listedTeams.isEmpty, pendingCreate == nil {
            menu.addItem(statusItem(
                String(localized: "sidebar.account.loadingTeams", defaultValue: "Loading teams…"),
                identifier: loadingTeamsIdentifier
            ))
        }
        for team in listedTeams {
            let item = SidebarRowClosureMenuItem(title: team.displayName) { onSelect(team) }
            item.identifier = NSUserInterfaceItemIdentifier(teamIdentifier(team.id))
            item.state = pendingCreate == nil && team.id == selectedTeamID ? .on : .off
            item.isEnabled = !isBusy
            menu.addItem(item)
        }
        if let pendingCreate {
            let item = statusItem(pendingCreate.displayName, identifier: pendingTeamIdentifier)
            item.state = .on
            menu.addItem(item)
        }
        if selectedTeamID != nil, let onInvite, let onMembers {
            menu.addItem(.separator())
            let invite = SidebarRowClosureMenuItem(
                title: String(localized: "sidebar.account.invitePeople", defaultValue: "Invite people…"),
                handler: onInvite
            )
            invite.identifier = NSUserInterfaceItemIdentifier("CloudTeamPickerInviteButton")
            invite.isEnabled = !isBusy
            menu.addItem(invite)
            let members = SidebarRowClosureMenuItem(
                title: String(localized: "sidebar.account.members", defaultValue: "Members…"),
                handler: onMembers
            )
            members.identifier = NSUserInterfaceItemIdentifier("CloudTeamPickerMembersButton")
            members.isEnabled = !isBusy
            menu.addItem(members)
        }
        if !invitations.isEmpty, let onJoin {
            menu.addItem(.separator())
            menu.addItem(statusItem(
                String(localized: "cloud.teamPicker.invitedTo", defaultValue: "Invited to"),
                identifier: invitedHeaderIdentifier
            ))
            for invitation in invitations {
                let item = SidebarRowClosureMenuItem(
                    title: String(
                        format: String(localized: "cloud.teamPicker.join", defaultValue: "Join %@"),
                        invitation.teamName
                    )
                ) { onJoin(invitation) }
                item.identifier = NSUserInterfaceItemIdentifier(invitationIdentifier(invitation.id))
                item.isEnabled = !isBusy
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let create = SidebarRowClosureMenuItem(
            title: String(localized: "cloud.teamPicker.createTeam", defaultValue: "Create Team…"),
            handler: onCreate
        )
        create.identifier = NSUserInterfaceItemIdentifier(createTeamIdentifier)
        create.isEnabled = !isBusy
        menu.addItem(create)
        return menu
    }

    private static func statusItem(_ title: String, identifier: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
        item.isEnabled = false
        return item
    }
}
