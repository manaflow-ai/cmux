import CmuxSettingsUI
import SwiftUI

/// The nested team menu. Selection and creation keep both menu levels open.
struct SidebarAccountTeamPicker: View {
    let accountFlow: HostAccountFlow
    @State private var isCreatingTeam = false
    @State private var newTeamName = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var isCreateFieldFocused: Bool
    private let menuRowHeight: CGFloat = 28

    var body: some View {
        teamPickerContent
        .buttonStyle(.plain)
        .disabled(isSubmitting || accountFlow.isWorkingOnAuth)
        .padding(12)
        .frame(width: 220, alignment: .leading)
    }

    @ViewBuilder
    private var teamPickerContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            if accountFlow.availableTeams.isEmpty {
                Text(String(localized: "sidebar.account.loadingTeams", defaultValue: "Loading teams…"))
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: menuRowHeight, alignment: .leading)
            } else {
                ForEach(accountFlow.availableTeams) { team in
                    teamRow(team)
                }
            }
            if isCreatingTeam {
                createTeamEditor
            } else {
                accountMenuRow(
                    title: String(localized: "sidebar.account.createTeam", defaultValue: "Create team…"),
                    systemImage: "plus"
                ) {
                    errorMessage = nil
                    newTeamName = ""
                    isCreatingTeam = true
                }
                .accessibilityIdentifier("SidebarAccountCreateTeamButton")
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

    private func teamRow(_ team: AccountTeamSummary) -> some View {
        let activeTeamID = accountFlow.selectedTeamID
        let isSelected = team.id == activeTeamID
        let isPending = team.id == accountFlow.pendingTeamSelection?.teamID
        return Button {
            guard !isSelected, !accountFlow.isSelectingTeam else { return }
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
        } label: {
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
            .frame(maxWidth: .infinity, minHeight: menuRowHeight, alignment: .leading)
        }
        .accessibilityLabel(String(
            format: String(localized: "sidebar.account.teamRowLabel", defaultValue: "%1$@%2$@"),
            team.displayName,
            isSelected ? String(localized: "sidebar.account.activeSuffix", defaultValue: ", active") : ""
        ))
        .accessibilityIdentifier("SidebarAccountTeam_\(team.id)")
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
            .frame(height: 24)
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
        .frame(minHeight: menuRowHeight, alignment: .leading)
        .onAppear { isCreateFieldFocused = true }
        .accessibilityIdentifier("SidebarAccountCreateTeamEditor")
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

    private func accountMenuRow(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: menuRowHeight, alignment: .leading)
        }
    }
}
