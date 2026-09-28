import CmuxFoundation
import SwiftUI

/// Names a new Cloud team. A sheet rather than an alert so a rejected name
/// keeps the dialog open with its error beside the field. Create makes the new
/// team active; Cancel waits for an in-flight request, since the server may
/// still create the team. Create waits, with a status, while another team
/// switch or create is pending, which the account flow would refuse.
struct CloudCreateTeamSheet: View {
    let accountFlow: HostAccountFlow
    let onFinish: () -> Void

    @State private var name = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A pending team switch, or another create, that Create has to wait for.
    private var pendingChangeStatus: String? {
        if accountFlow.isSelectingTeam {
            return String(localized: "cloud.teamPicker.switching", defaultValue: "Switching teams…")
        }
        if accountFlow.isCreatingTeam, !isSubmitting {
            return String(localized: "cloud.teamPicker.creating", defaultValue: "Creating team…")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "cloud.teamPicker.createSheet.title", defaultValue: "Create Team"))
                .cmuxFont(size: 15, weight: .semibold)
            TextField(
                String(localized: "sidebar.account.createTeamPlaceholder", defaultValue: "Team name"),
                text: $name
            )
            .textFieldStyle(.roundedBorder)
            .focused($isNameFocused)
            .disabled(isSubmitting)
            .onSubmit(submit)
            .accessibilityIdentifier("CloudCreateTeamSheet.name")
            if let errorMessage {
                Text(errorMessage)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("CloudCreateTeamSheet.error")
            }
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView().controlSize(.small)
                } else if let pendingChangeStatus {
                    Text(pendingChangeStatus)
                        .cmuxFont(size: 11)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CloudCreateTeamSheet.pendingChange")
                }
                Spacer()
                Button(String(localized: "sidebar.account.createTeamCancel", defaultValue: "Cancel"), action: onFinish)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("CloudCreateTeamSheet.cancel")
                Button(String(localized: "cloud.teamPicker.createSheet.create", defaultValue: "Create"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty || isSubmitting || pendingChangeStatus != nil)
                    .accessibilityIdentifier("CloudCreateTeamSheet.create")
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { isNameFocused = true }
        .onChange(of: name) { errorMessage = nil }
    }

    private func submit() {
        let displayName = trimmedName
        guard !displayName.isEmpty, !isSubmitting, pendingChangeStatus == nil else { return }
        isSubmitting = true
        errorMessage = nil
        Task { @MainActor in
            do {
                _ = try await accountFlow.createTeam(displayName: displayName)
                isSubmitting = false
                onFinish()
            } catch {
                isSubmitting = false
                errorMessage = String(
                    localized: "sidebar.account.createTeamFailed",
                    defaultValue: "Could not create that team. Try again."
                )
                isNameFocused = true
            }
        }
    }
}
