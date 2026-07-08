import AppKit
import CmuxFleet
import SwiftUI

struct FleetConfigSheet: View {
    @ObservedObject var store: FleetBoardStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var repoRoot = ""
    @State private var agentCommand = FleetConfig(
        id: "template",
        name: "",
        repoRoot: "",
        workspaceRoot: ""
    ).agentCommandTemplate
    @State private var maxConcurrent = 3
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField(String(localized: "fleet.config.name", defaultValue: "Name"), text: $name)

                HStack {
                    TextField(
                        String(localized: "fleet.config.repoRoot", defaultValue: "Repository root"),
                        text: $repoRoot
                    )
                    Button(String(localized: "fleet.config.choose", defaultValue: "Choose...")) {
                        chooseRepositoryRoot()
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    TextField(
                        String(localized: "fleet.config.agentCommand", defaultValue: "Agent command template"),
                        text: $agentCommand
                    )
                    .font(.system(.body, design: .monospaced))
                    Text(String(localized: "fleet.config.agentCommand.caption", defaultValue: "Use {{PROMPT}} where the task prompt should be inserted. Other placeholders include {{TITLE}}, {{BODY}}, {{TASK_ID}}, {{DIR}}, and {{BRANCH}}."))
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Stepper(
                    String.localizedStringWithFormat(
                        String(localized: "fleet.config.maxConcurrent", defaultValue: "Max concurrent agents: %d"),
                        maxConcurrent
                    ),
                    value: $maxConcurrent,
                    in: 1...32
                )
            }

            if let errorMessage {
                Text(errorMessage)
                    .cmuxFont(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            HStack {
                Spacer()
                Button(String(localized: "fleet.config.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                Button(String(localized: "fleet.config.create", defaultValue: "Create")) {
                    create()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520)
    }

    private func chooseRepositoryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "fleet.config.choose.title", defaultValue: "Choose Repository Root")
        panel.prompt = String(localized: "fleet.config.choose.prompt", defaultValue: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            repoRoot = url.path
        }
    }

    private func create() {
        switch store.createFleet(
            name: name,
            repoRoot: repoRoot,
            agentCommand: agentCommand,
            maxConcurrent: maxConcurrent
        ) {
        case .success:
            dismiss()
        case .failure(.invalidConfiguration(let reason)):
            errorMessage = String.localizedStringWithFormat(
                String(localized: "fleet.config.error.invalidConfiguration", defaultValue: "Could not create Fleet: %@"),
                reason
            )
        }
    }
}
