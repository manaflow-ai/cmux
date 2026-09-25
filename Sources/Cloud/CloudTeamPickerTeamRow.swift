import CmuxSettingsUI
import SwiftUI

/// A value snapshot keeps the team's observable owner above the list boundary.
struct CloudTeamPickerTeamRow: View {
    let team: AccountTeamSummary
    let isSelected: Bool
    let isPending: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Label(team.displayName, systemImage: "person.2")
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isPending {
                    ProgressView().controlSize(.mini)
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(String(
            format: String(localized: "sidebar.account.teamRowLabel", defaultValue: "%1$@%2$@"),
            team.displayName,
            isSelected ? String(localized: "sidebar.account.activeSuffix", defaultValue: ", active") : ""
        ))
        .accessibilityIdentifier("CloudTeamPickerTeam_\(team.id)")
    }
}
