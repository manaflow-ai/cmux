import SwiftUI

/// Picker bound to the host's ``AccountFlow/selectedTeamID`` so the
/// user can switch between teams without leaving Settings.
@MainActor
struct AccountTeamPicker: View {
    let flow: AccountFlow

    var body: some View {
        Picker("Active Team", selection: Binding(
            get: { flow.selectedTeamID ?? "" },
            set: { newValue in
                flow.selectedTeamID = newValue.isEmpty ? nil : newValue
            }
        )) {
            Text("None").tag("")
            ForEach(flow.availableTeams) { team in
                Text(team.displayName).tag(team.id)
            }
        }
    }
}
