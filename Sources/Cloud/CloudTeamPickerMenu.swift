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

    static func teamIdentifier(_ teamID: String) -> String {
        "CloudTeamPickerTeam_\(teamID)"
    }

    static func make(
        teams: [AccountTeamSummary],
        selectedTeamID: String?,
        isSwitching: Bool,
        pendingCreate: PendingTeamCreate?,
        onSelect: @escaping (AccountTeamSummary) -> Void,
        onCreate: @escaping () -> Void
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
