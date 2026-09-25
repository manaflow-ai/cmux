import CmuxSettingsUI
import SwiftUI

/// The Cloud team menu. Selection and creation use the shared account flow.
struct CloudTeamPicker: View {
    let accountFlow: HostAccountFlow
    @State private var isCreatingTeam = false
    @State private var newTeamName = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var isCreateFieldFocused: Bool

    var body: some View {
        teamPickerContent
            .buttonStyle(SidebarAccountMenuButtonStyle())
            .disabled(isSubmitting || accountFlow.isWorkingOnAuth)
            .padding(12)
            .frame(width: 220, alignment: .leading)
    }

    @ViewBuilder
    private var teamPickerContent: some View {
        let teams = accountFlow.availableTeams
        let selectedTeamID = accountFlow.selectedTeamID
        let pendingTeamID = accountFlow.pendingTeamSelection?.teamID
        VStack(alignment: .leading, spacing: 0) {
            if teams.isEmpty {
                Text(String(localized: "sidebar.account.loadingTeams", defaultValue: "Loading teams…"))
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: SidebarAccountMenuButtonStyle.rowHeight, alignment: .leading)
            } else {
                ForEach(teams) { team in
                    CloudTeamPickerTeamRow(
                        team: team,
                        isSelected: team.id == selectedTeamID,
                        isPending: team.id == pendingTeamID,
                        onSelect: { selectTeam(team) }
                    )
                }
            }
            if isCreatingTeam {
                createTeamEditor
            } else {
                teamMenuRow(
                    title: String(localized: "sidebar.account.createTeam", defaultValue: "Create team…"),
                    systemImage: "plus"
                ) {
                    errorMessage = nil
                    newTeamName = ""
                    isCreatingTeam = true
                }
                .accessibilityIdentifier("CloudTeamPickerCreateTeamButton")
            }
            if let errorMessage {
                Text(errorMessage)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
                    .accessibilityLabel(errorMessage)
            }
        }
    }

    private func selectTeam(_ team: AccountTeamSummary) {
        guard team.id != accountFlow.selectedTeamID, !accountFlow.isSelectingTeam else { return }
        errorMessage = nil
        Task { @MainActor in
            do {
                try await accountFlow.selectTeam(id: team.id)
            } catch {
                errorMessage = String(
                    localized: "sidebar.account.switchTeamFailed",
                    defaultValue: "Could not switch teams. Try again."
                )
            }
        }
    }

    private var createTeamEditor: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus")
                .frame(width: 16)
                .foregroundStyle(.secondary)
            TextField(
                String(localized: "sidebar.account.createTeamPlaceholder", defaultValue: "Team name"),
                text: $newTeamName
            )
            .textFieldStyle(.plain)
            .focused($isCreateFieldFocused)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .onSubmit { submitCreateTeam() }
            if isSubmitting {
                ProgressView().controlSize(.mini).frame(width: 22, height: 22)
            } else {
                Button {
                    submitCreateTeam()
                } label: {
                    Image(systemName: "checkmark").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(newTeamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "sidebar.account.createTeamSubmit", defaultValue: "Create team"))
                Button {
                    isCreateFieldFocused = false
                    isCreatingTeam = false
                } label: {
                    Image(systemName: "xmark").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "sidebar.account.createTeamCancel", defaultValue: "Cancel"))
            }
        }
        .padding(.leading, 1)
        .padding(.vertical, 2)
        .frame(minHeight: SidebarAccountMenuButtonStyle.rowHeight, alignment: .leading)
        .onAppear { isCreateFieldFocused = true }
        .accessibilityIdentifier("CloudTeamPickerCreateTeamEditor")
    }

    private func submitCreateTeam() {
        let name = newTeamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                _ = try await accountFlow.createTeam(displayName: name)
                isCreateFieldFocused = false
                isCreatingTeam = false
                newTeamName = ""
            } catch {
                errorMessage = String(
                    localized: "sidebar.account.createTeamFailed",
                    defaultValue: "Could not create that team. Try again."
                )
            }
        }
    }

    private func teamMenuRow(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
