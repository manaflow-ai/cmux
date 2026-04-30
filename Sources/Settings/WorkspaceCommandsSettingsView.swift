import AppKit
import SwiftUI

/// List/detail editor for the user's workspace commands. Surfaced in its own
/// window (opened from `Settings → Workspaces → Manage Workspaces…`) because
/// the schema is wide enough that inlining it in the main settings scroll
/// would dominate the page.
struct WorkspaceCommandsSettingsView: View {
    static let windowID = "workspace-commands-editor"

    @ObservedObject private var store = WorkspaceCommandsStore.shared
    @State private var selectedID: WorkspaceCommandConfig.ID?

    @State private var showRestoreConfirmation = false

    var body: some View {
        NavigationSplitView {
            commandList
        } detail: {
            if let id = selectedID,
               let snapshot = store.command(id: id) {
                if store.isBuiltIn(id: id) {
                    BuiltInWorkspaceCommandView(
                        command: snapshot,
                        isDefault: store.defaultCommandID == nil
                            || store.defaultCommandID == id,
                        onMakeDefault: { store.setDefault(id: nil) }
                    )
                    .id(id)
                } else if let binding = bindingForCommand(id: id) {
                    WorkspaceCommandDetailEditor(
                        command: binding,
                        isDefault: store.defaultCommandID == id,
                        onToggleDefault: { store.setDefault(id: $0 ? id : nil) },
                        onDelete: {
                            store.remove(id: id)
                            selectedID = WorkspaceCommandsStore.builtInLocalID
                        }
                    )
                    .id(id)
                }
            } else {
                emptyDetail
            }
        }
        .navigationTitle(String(
            localized: "settings.workspaces.windowTitle",
            defaultValue: "Workspaces"
        ))
        .frame(minWidth: 720, minHeight: 460)
        .onAppear {
            if selectedID == nil {
                selectedID = WorkspaceCommandsStore.builtInLocalID
            }
        }
        .alert(
            String(
                localized: "settings.workspaces.restoreDefaults.confirm.title",
                defaultValue: "Restore Default Workspaces?"
            ),
            isPresented: $showRestoreConfirmation
        ) {
            Button(role: .destructive) {
                store.restoreDefaults()
                selectedID = WorkspaceCommandsStore.builtInLocalID
            } label: {
                Text(String(
                    localized: "settings.workspaces.restoreDefaults.confirm.button",
                    defaultValue: "Restore"
                ))
            }
            Button(role: .cancel) {} label: {
                Text(String(
                    localized: "settings.workspaces.restoreDefaults.confirm.cancel",
                    defaultValue: "Cancel"
                ))
            }
        } message: {
            Text(String(
                localized: "settings.workspaces.restoreDefaults.confirm.message",
                defaultValue: "This removes every workspace command you've added and leaves only the built-in Local workspace. This cannot be undone."
            ))
        }
    }

    private var commandList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(store.commands) { command in
                    WorkspaceCommandListRow(
                        name: command.name,
                        isRemote: command.remote != nil,
                        isDefault: store.defaultCommandID == command.id
                            || (store.defaultCommandID == nil
                                && command.id == WorkspaceCommandsStore.builtInLocalID)
                    )
                    .tag(command.id as WorkspaceCommandConfig.ID?)
                }
                .onMove { source, destination in
                    store.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 8) {
                Button {
                    let new = store.addCommand()
                    selectedID = new.id
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(String(
                    localized: "settings.workspaces.addCommand",
                    defaultValue: "Add workspace command"
                ))

                Button {
                    if let id = selectedID, !store.isBuiltIn(id: id) {
                        store.remove(id: id)
                        selectedID = WorkspaceCommandsStore.builtInLocalID
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedID.map { store.isBuiltIn(id: $0) } ?? true)
                .help(String(
                    localized: "settings.workspaces.removeCommand",
                    defaultValue: "Remove selected command"
                ))

                Spacer()

                Button {
                    showRestoreConfirmation = true
                } label: {
                    Text(String(
                        localized: "settings.workspaces.restoreDefaults",
                        defaultValue: "Restore Defaults"
                    ))
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(store.userCommands.isEmpty && store.defaultCommandID == nil)
                .help(String(
                    localized: "settings.workspaces.restoreDefaults.help",
                    defaultValue: "Remove all custom commands and reset to just Local"
                ))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 300, max: 360)
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(.secondary)
            Text(String(
                localized: "settings.workspaces.empty.title",
                defaultValue: "No workspace selected"
            ))
                .font(.headline)
            Text(String(
                localized: "settings.workspaces.empty.subtitle",
                defaultValue: "Select a workspace command on the left, or click + to create one."
            ))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bindingForCommand(id: WorkspaceCommandConfig.ID) -> Binding<WorkspaceCommandConfig>? {
        guard let initial = store.command(id: id) else { return nil }
        return Binding(
            get: { store.command(id: id) ?? initial },
            set: { store.update($0) }
        )
    }
}

private struct WorkspaceCommandListRow: View {
    let name: String
    let isRemote: Bool
    let isDefault: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isRemote ? "network" : "terminal")
                .foregroundColor(.secondary)
            Text(name.isEmpty
                 ? String(localized: "settings.workspaces.unnamed", defaultValue: "Untitled")
                 : name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if isDefault {
                Text(String(
                    localized: "settings.workspaces.defaultBadge",
                    defaultValue: "Default"
                ))
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                )
            }
        }
    }
}

private struct BuiltInWorkspaceCommandView: View {
    let command: WorkspaceCommandConfig
    let isDefault: Bool
    let onMakeDefault: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(command.name)
                        .foregroundColor(.secondary)
                } label: {
                    Text(String(localized: "settings.workspaces.field.name", defaultValue: "Name"))
                }
                Toggle(
                    String(
                        localized: "settings.workspaces.field.useAsDefault",
                        defaultValue: "Use as default for new workspaces (Cmd-N)"
                    ),
                    isOn: Binding(
                        get: { isDefault },
                        set: { isOn in
                            // Local is the fallback when no default is set, so we
                            // only act on "turn on": switch the explicit default
                            // back to Local. Turning it off has no meaning — pick
                            // a different command's "default" toggle instead.
                            if isOn { onMakeDefault() }
                        }
                    )
                )
                .disabled(isDefault)
            }
            Section {
                Text(String(
                    localized: "settings.workspaces.builtIn.local.note",
                    defaultValue: "Local is built into cmux. It opens a new workspace using your default shell. To customize it, add a separate workspace command."
                ))
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }
}

private struct WorkspaceCommandDetailEditor: View {
    @Binding var command: WorkspaceCommandConfig
    let isDefault: Bool
    let onToggleDefault: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        Form {
            Section {
                TextField(
                    String(localized: "settings.workspaces.field.name", defaultValue: "Name"),
                    text: $command.name
                )
                Picker(
                    String(localized: "settings.workspaces.field.restart", defaultValue: "Open behavior"),
                    selection: $command.restart
                ) {
                    ForEach(WorkspaceCommandConfig.Restart.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Toggle(
                    String(
                        localized: "settings.workspaces.field.useAsDefault",
                        defaultValue: "Use as default for new workspaces (Cmd-N)"
                    ),
                    isOn: Binding(
                        get: { isDefault },
                        set: { onToggleDefault($0) }
                    )
                )
            }

            if command.remote == nil {
                Section(String(
                    localized: "settings.workspaces.section.local",
                    defaultValue: "Local"
                )) {
                    let programBinding = Binding<String>(
                        get: { command.program ?? "" },
                        set: { newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            command.program = trimmed.isEmpty ? nil : trimmed
                        }
                    )
                    TextField(
                        String(
                            localized: "settings.workspaces.field.program",
                            defaultValue: "Program"
                        ),
                        text: programBinding,
                        prompt: Text(verbatim: "/bin/zsh -l")
                    )
                    Text(String(
                        localized: "settings.workspaces.field.program.help",
                        defaultValue: "Optional. Leave empty to use your default shell. Provide a full path (e.g. /opt/homebrew/bin/fish) or a command with arguments. The pane closes automatically when the program exits."
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }

            Section(String(localized: "settings.workspaces.section.remote", defaultValue: "Remote (SSH)")) {
                Toggle(
                    String(
                        localized: "settings.workspaces.field.remoteEnabled",
                        defaultValue: "Connect via SSH"
                    ),
                    isOn: Binding(
                        get: { command.remote != nil },
                        set: { enabled in
                            if enabled, command.remote == nil {
                                command.remote = WorkspaceCommandConfig.Remote()
                            } else if !enabled {
                                command.remote = nil
                            }
                        }
                    )
                )

                if command.remote != nil {
                    remoteFields
                }
            }

            Section {
                Button(role: .destructive, action: onDelete) {
                    Text(String(
                        localized: "settings.workspaces.deleteCommand",
                        defaultValue: "Delete Workspace Command"
                    ))
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var remoteFields: some View {
        let hostBinding = Binding(
            get: { command.remote?.host ?? "" },
            set: { command.remote?.host = $0 }
        )
        TextField(
            String(localized: "settings.workspaces.field.host", defaultValue: "Host"),
            text: hostBinding,
            prompt: Text(verbatim: "user@host.example.com")
        )

        let portBinding = Binding<String>(
            get: { command.remote?.port.map(String.init) ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    command.remote?.port = nil
                } else if let port = Int(trimmed), (1...65535).contains(port) {
                    command.remote?.port = port
                }
            }
        )
        TextField(
            String(localized: "settings.workspaces.field.port", defaultValue: "Port"),
            text: portBinding,
            prompt: Text(verbatim: "22")
        )

        let identityBinding = Binding(
            get: { command.remote?.identityFile ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                command.remote?.identityFile = trimmed.isEmpty ? nil : trimmed
            }
        )
        TextField(
            String(localized: "settings.workspaces.field.identityFile", defaultValue: "Identity file"),
            text: identityBinding,
            prompt: Text(verbatim: "~/.ssh/id_ed25519")
        )

        let optionsBinding = Binding<String>(
            get: { (command.remote?.sshOptions ?? []).joined(separator: "\n") },
            set: { newValue in
                let lines = newValue
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                command.remote?.sshOptions = lines
            }
        )
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "settings.workspaces.field.sshOptions", defaultValue: "SSH options (one per line)"))
                .font(.subheadline)
            TextEditor(text: optionsBinding)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 60, maxHeight: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }

        let startupBinding = Binding(
            get: { command.remote?.startupCommand ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                command.remote?.startupCommand = trimmed.isEmpty ? nil : trimmed
            }
        )
        TextField(
            String(localized: "settings.workspaces.field.startupCommand", defaultValue: "Startup command"),
            text: startupBinding,
            prompt: Text(verbatim: "tmux attach || tmux new")
        )
    }
}
