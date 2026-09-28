import AppKit
import CmuxSettingsUI

/// Builds the Cloud header's team pull-down from one snapshot of account state.
///
/// Rows are native menu items, so team names are never clipped to a fixed
/// width and the active team carries the standard checkmark. While a switch or
/// a team create is pending, a status row says so and every action is
/// disabled, so a second request cannot race the first.
@MainActor
enum CloudTeamPickerMenu {
    static let switchingStatusIdentifier = "CloudTeamPickerSwitchingStatus"
    static let creatingStatusIdentifier = "CloudTeamPickerCreatingStatus"
    static let loadingTeamsIdentifier = "CloudTeamPickerLoadingTeams"
    static let createTeamIdentifier = "CloudTeamPickerCreateTeamButton"

    static func teamIdentifier(_ teamID: String) -> String {
        "CloudTeamPickerTeam_\(teamID)"
    }

    static func make(
        teams: [AccountTeamSummary],
        selectedTeamID: String?,
        isSwitching: Bool,
        isCreatingTeam: Bool,
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
        if isCreatingTeam {
            menu.addItem(statusItem(
                String(localized: "cloud.teamPicker.creating", defaultValue: "Creating team…"),
                identifier: creatingStatusIdentifier
            ))
        }
        let isBusy = isSwitching || isCreatingTeam
        if isBusy {
            menu.addItem(.separator())
        }
        if teams.isEmpty {
            menu.addItem(statusItem(
                String(localized: "sidebar.account.loadingTeams", defaultValue: "Loading teams…"),
                identifier: loadingTeamsIdentifier
            ))
        }
        for team in teams {
            let item = SidebarRowClosureMenuItem(title: team.displayName) { onSelect(team) }
            item.identifier = NSUserInterfaceItemIdentifier(teamIdentifier(team.id))
            item.state = team.id == selectedTeamID ? .on : .off
            item.isEnabled = !isBusy
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
