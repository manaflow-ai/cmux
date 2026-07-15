import CmuxFoundation
import CmuxSettings
import SwiftUI

@MainActor
struct TerminalScriptsSettingsCard: View {
    private let hostActions: SettingsHostActions

    @State private var location: JSONValueModel<TerminalSetupScriptLocation>
    @State private var commands: JSONValueModel<SavedTerminalCommandLibrary>
    @State private var editingCommandID: String?
    @State private var commandName = ""
    @State private var commandBody = ""
    @State private var repositoryContext: RepositoryScriptSettingsContext?
    @State private var repositorySetup = ""
    @State private var repositoryArchive = ""
    @State private var repositorySaveFailed = false
    @State private var repositorySaveTask: Task<Void, Never>?

    init(
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        hostActions: SettingsHostActions
    ) {
        self.hostActions = hostActions
        _location = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.terminal.setupScriptLocation,
            errorLog: errorLog
        ))
        _commands = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.terminal.savedCommands,
            errorLog: errorLog
        ))
    }

    var body: some View {
        Group {
            SettingsCard {
                SettingsCardRow(
                    configurationReview: .json("terminal.setupScriptLocation"),
                    String(localized: "settings.terminal.setup.location", defaultValue: "Setup Script Location"),
                    subtitle: String(
                        localized: "settings.terminal.setup.location.subtitle",
                        defaultValue: "Choose where an automatic repository setup script opens. Background tabs never steal focus."
                    )
                ) {
                    Picker("", selection: locationBinding) {
                        ForEach(TerminalSetupScriptLocation.allCases, id: \.self) { value in
                            Text(locationLabel(value)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
            }
            repositoryCard
            savedCommandsCard
        }
        .task {
            location.startObserving()
            commands.startObserving()
            await refreshRepositoryContext()
        }
        .onDisappear { repositorySaveTask?.cancel() }
    }

    private var locationBinding: Binding<TerminalSetupScriptLocation> {
        Binding(get: { location.current }, set: { location.set($0) })
    }

    private func locationLabel(_ value: TerminalSetupScriptLocation) -> String {
        switch value {
        case .backgroundTab:
            return String(localized: "settings.terminal.setup.location.backgroundTab", defaultValue: "Background Tab")
        case .verticalSplit:
            return String(localized: "settings.terminal.setup.location.verticalSplit", defaultValue: "Vertical Split")
        case .horizontalSplit:
            return String(localized: "settings.terminal.setup.location.horizontalSplit", defaultValue: "Horizontal Split")
        }
    }

    @ViewBuilder
    private var repositoryCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                if let context = repositoryContext {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "settings.terminal.repositoryScripts", defaultValue: "Repository Scripts"))
                                .cmuxFont(.body, weight: .medium)
                            Text(context.repositoryName)
                                .cmuxFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if context.projectSetup != nil || context.projectArchive != nil {
                            Button(String(
                                localized: "settings.terminal.repositoryScripts.import",
                                defaultValue: "Import Project Scripts"
                            )) {
                                importProjectScripts()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    scriptEditor(
                        title: String(localized: "settings.terminal.repositoryScripts.setup", defaultValue: "Setup"),
                        text: $repositorySetup,
                        accessibilityID: "SettingsRepositorySetupScriptEditor"
                    )
                    scriptEditor(
                        title: String(localized: "settings.terminal.repositoryScripts.archive", defaultValue: "Archive"),
                        text: $repositoryArchive,
                        accessibilityID: "SettingsRepositoryArchiveScriptEditor"
                    )
                    HStack {
                        Text(String(
                            localized: "settings.terminal.repositoryScripts.security",
                            defaultValue: "Project-file scripts require trust before they run. Scripts saved here are private user settings."
                        ))
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        if repositorySaveFailed {
                            Text(String(localized: "settings.terminal.repositoryScripts.saveFailed", defaultValue: "Couldn't save."))
                                .cmuxFont(.caption)
                                .foregroundStyle(.red)
                        }
                        Button(String(localized: "settings.terminal.repositoryScripts.save", defaultValue: "Save")) {
                            saveRepositoryScripts()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                } else {
                    SettingsCardRow(
                        configurationReview: .settingsOnly,
                        String(localized: "settings.terminal.repositoryScripts", defaultValue: "Repository Scripts"),
                        subtitle: String(
                            localized: "settings.terminal.repositoryScripts.noRepository",
                            defaultValue: "Focus a workspace inside a Git repository to edit its setup and archive scripts."
                        )
                    ) { EmptyView() }
                }
            }
            .padding(14)
        }
        .settingsSearchAnchors(["setting:terminal:repository-scripts"])
    }

    private func scriptEditor(title: String, text: Binding<String>, accessibilityID: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).cmuxFont(.caption, weight: .medium)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 72, maxHeight: 120)
                .padding(5)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .accessibilityIdentifier(accessibilityID)
        }
    }

    @ViewBuilder
    private var savedCommandsCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "settings.terminal.savedCommands", defaultValue: "Saved Commands"))
                            .cmuxFont(.body, weight: .medium)
                        Text(String(
                            localized: "settings.terminal.savedCommands.subtitle",
                            defaultValue: "Named multiline commands appear in the command palette and run in the focused terminal."
                        ))
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(String(localized: "settings.terminal.savedCommands.add", defaultValue: "Add Command")) {
                        beginAddingCommand()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                ForEach(commands.current.commands) { command in
                    Divider()
                    SavedTerminalCommandRow(
                        command: command,
                        onEdit: { beginEditing(command) },
                        onDelete: { deleteCommand(id: command.id) }
                    )
                }

                if editingCommandID != nil {
                    Divider()
                    savedCommandEditor
                }
            }
            .padding(14)
        }
        .settingsSearchAnchors(["setting:terminal:saved-commands"])
    }

    private var savedCommandEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                String(localized: "settings.terminal.savedCommands.name", defaultValue: "Command name"),
                text: $commandName
            )
            TextEditor(text: $commandBody)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 82)
                .padding(5)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            if isDuplicateCommandName, editingCommandID != nil {
                Text(String(
                    localized: "settings.terminal.savedCommands.duplicateName",
                    defaultValue: "Command names must be unique."
                ))
                .cmuxFont(.caption)
                .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(String(localized: "settings.common.cancel", defaultValue: "Cancel")) { cancelCommandEdit() }
                Button(String(localized: "settings.common.save", defaultValue: "Save")) { saveCommand() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        commandBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        isDuplicateCommandName
                    )
            }
        }
    }

    private func beginAddingCommand() {
        editingCommandID = UUID().uuidString
        commandName = ""
        commandBody = ""
    }

    private func beginEditing(_ command: SavedTerminalCommand) {
        editingCommandID = command.id
        commandName = command.name
        commandBody = command.command
    }

    private func cancelCommandEdit() {
        editingCommandID = nil
        commandName = ""
        commandBody = ""
    }

    private func saveCommand() {
        guard let editingCommandID else { return }
        var updated = commands.current
        guard updated.save(SavedTerminalCommand(
            id: editingCommandID,
            name: commandName,
            command: commandBody
        )) else { return }
        commands.set(updated)
        cancelCommandEdit()
    }

    private func deleteCommand(id: String) {
        var updated = commands.current
        updated.remove(id: id)
        commands.set(updated)
        if editingCommandID == id { cancelCommandEdit() }
    }

    private var isDuplicateCommandName: Bool {
        guard let editingCommandID else { return false }
        let trimmed = commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !commands.current.canSave(name: trimmed, id: editingCommandID)
    }

    private func refreshRepositoryContext() async {
        let context = await hostActions.repositoryScriptSettingsContext()
        guard !Task.isCancelled else { return }
        repositoryContext = context
        repositorySetup = context?.setup ?? ""
        repositoryArchive = context?.archive ?? ""
    }

    private func saveRepositoryScripts() {
        repositorySaveTask?.cancel()
        repositorySaveTask = Task {
            let saved = await hostActions.saveRepositoryScripts(
                setup: repositorySetup,
                archive: repositoryArchive
            )
            if !Task.isCancelled {
                repositorySaveFailed = !saved
                if saved { await refreshRepositoryContext() }
            }
        }
    }

    private func importProjectScripts() {
        repositorySaveTask?.cancel()
        repositorySaveTask = Task {
            let saved = await hostActions.importProjectRepositoryScripts()
            if !Task.isCancelled {
                repositorySaveFailed = !saved
                if saved { await refreshRepositoryContext() }
            }
        }
    }
}
