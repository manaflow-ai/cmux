import SwiftUI

struct NewGoalPopover: View {
    let currentWorkspacePath: String?
    let onCreate: (String, String, String?) -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var acceptanceCriteria = ""
    @State private var usesCurrentWorkspace = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "goals.new.title", defaultValue: "New Goal"))
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "goals.field.title", defaultValue: "Title"))
                    .font(.system(size: 11, weight: .medium))
                TextField(
                    String(localized: "goals.field.title.placeholder", defaultValue: "Ship onboarding flow"),
                    text: $title
                )
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "goals.field.acceptanceCriteria", defaultValue: "Acceptance criteria"))
                    .font(.system(size: 11, weight: .medium))
                TextEditor(text: $acceptanceCriteria)
                    .font(.system(size: 12))
                    .frame(width: 300, height: 92)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    )
            }

            if currentWorkspacePath != nil {
                Toggle(isOn: $usesCurrentWorkspace) {
                    Text(String(localized: "goals.field.currentWorkspace", defaultValue: "Link current workspace"))
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
            }

            HStack {
                Spacer(minLength: 0)
                Button(String(localized: "goals.new.cancel", defaultValue: "Cancel")) {
                    onCancel()
                }
                Button(String(localized: "goals.new.create", defaultValue: "Create")) {
                    onCreate(
                        title,
                        acceptanceCriteria,
                        usesCurrentWorkspace ? currentWorkspacePath : nil
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 328)
    }
}
