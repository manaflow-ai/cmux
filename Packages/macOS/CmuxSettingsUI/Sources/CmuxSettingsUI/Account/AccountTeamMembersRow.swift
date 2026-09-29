import SwiftUI

/// Opens the host's members-and-invites surface for the selected team.
@MainActor
struct AccountTeamMembersRow: View {
    let flow: AccountFlow

    var body: some View {
        SettingsCardRow(
            String(localized: "settings.account.teamMembers", defaultValue: "Members and Invites"),
            controlWidth: 196
        ) {
            Button(String(localized: "settings.account.teamMembers.open", defaultValue: "Manage…")) {
                flow.openTeamMembers()
            }
            .controlSize(.small)
            .disabled(flow.isWorkingOnAuth)
            .accessibilityIdentifier("SettingsAccountTeamMembersButton")
        }
    }
}
