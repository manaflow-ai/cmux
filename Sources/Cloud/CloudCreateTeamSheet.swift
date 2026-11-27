import CmuxFoundation
import SwiftUI

/// Names a new Cloud team. Create hands the name back and the sheet closes at
/// once: the Cloud header shows the new team as active while the server works,
/// and reports a rejected name there. Create waits, with a status, while
/// another team switch or create is pending, which the account flow would refuse.
struct CloudCreateTeamSheet: View {
    let accountFlow: HostAccountFlow
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @FocusState private var isNameFocused: Bool

    init(
        accountFlow: HostAccountFlow,
        initialName: String = "",
        onCreate: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.accountFlow = accountFlow
        self.onCreate = onCreate
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A pending team switch, or another create, that Create has to wait for.
    private var pendingChangeStatus: String? {
        if accountFlow.isSelectingTeam {
            return String(localized: "cloud.teamPicker.switching", defaultValue: "Switching teams…")
        }
        if accountFlow.isCreatingTeam {
            return String(localized: "cloud.teamPicker.creating", defaultValue: "Creating team…")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "cloud.teamPicker.createSheet.title", defaultValue: "Create Team"))
                .cmuxFont(size: 13, weight: .semibold)
            Text(String(
                localized: "cloud.teamPicker.createSheet.message",
                defaultValue: "The new team becomes your active team."
            ))
            .cmuxFont(size: 11)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
            TextField(
                String(localized: "sidebar.account.createTeamPlaceholder", defaultValue: "Team name"),
                text: $name
            )
            .textFieldStyle(.roundedBorder)
            .focused($isNameFocused)
            .onSubmit(submit)
            .accessibilityIdentifier("CloudCreateTeamSheet.name")
            .padding(.top, 12)
            HStack(spacing: 8) {
                if let pendingChangeStatus {
                    Text(pendingChangeStatus)
                        .cmuxFont(size: 11)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CloudCreateTeamSheet.pendingChange")
                }
                Spacer(minLength: 0)
                Button(String(localized: "sidebar.account.createTeamCancel", defaultValue: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("CloudCreateTeamSheet.cancel")
                Button(String(localized: "cloud.teamPicker.createSheet.create", defaultValue: "Create"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || pendingChangeStatus != nil)
                    .accessibilityIdentifier("CloudCreateTeamSheet.create")
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { isNameFocused = true }
    }

    private func submit() {
        let displayName = trimmedName
        guard !displayName.isEmpty, pendingChangeStatus == nil else { return }
        onCreate(displayName)
    }
}
