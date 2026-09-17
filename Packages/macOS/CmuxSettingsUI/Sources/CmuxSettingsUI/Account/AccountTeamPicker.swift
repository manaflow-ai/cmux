import SwiftUI

/// Picker bound to the host's ``AccountFlow/selectedTeamID`` so the
/// user can switch between teams without leaving Settings.
@MainActor
struct AccountTeamPicker: View {
    let flow: AccountFlow

    var body: some View {
        Picker(
            String(localized: "settings.account.activeTeam", defaultValue: "Active Team"),
            selection: Binding(
                get: { flow.selectedTeamID ?? "" },
                set: { newValue in
                    flow.selectedTeamID = newValue.isEmpty ? nil : newValue
                }
            )
        ) {
            Text(String(localized: "settings.account.activeTeam.none", defaultValue: "None")).tag("")
            ForEach(flow.availableTeams) { team in
                Text(team.displayName).tag(team.id)
            }
        }
    }
}
