import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Custom Commands** card on the Keyboard Shortcuts settings page.
///
/// Lets the user bind a single keystroke to any Command Palette command that
/// ships without a built-in shortcut (the example from the feature request:
/// "Open Current Directory in VS Code"). Bindings persist under
/// `shortcuts.commands` in cmux.json; the app target dispatches a match on the
/// focused window.
///
/// Unlike the per-action recorder rows above it (which override built-in cmux
/// actions in `shortcuts.bindings`), this card adds *new* bindings keyed by
/// command id. Recording a keystroke already used by a built-in action or
/// another command is blocked with a banner so a custom binding can never
/// silently shadow a built-in action or collide with another command.
@MainActor
struct CustomCommandShortcutsCard: View {
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog
    private let errorLog: SettingsErrorLog
    private let hostActions: SettingsHostActions

    /// Bound command shortcuts streamed from `shortcuts.commands`.
    @State private var commandShortcuts: [String: StoredShortcut] = [:]
    /// Built-in action overrides streamed from `shortcuts.bindings`, used (with
    /// each action's default) for conflict detection against built-in actions.
    @State private var actionBindings: [String: StoredShortcut] = [:]
    /// The full command catalog (id → title/subtitle/keywords), loaded once from
    /// the host so bound rows can resolve a command id back to a title.
    @State private var catalogEntries: [CommandShortcutCatalogEntry] = []
    @State private var commandStreamTask: Task<Void, Never>?
    @State private var bindingStreamTask: Task<Void, Never>?

    @State private var isPickerPresented = false
    /// Per-command re-record conflict banner: command id → conflicting label.
    @State private var rowConflicts: [String: String] = [:]
    /// Per-command bare-key (no modifier) rejection banner.
    @State private var rowBareKeyRejections: Set<String> = []

    init(
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        hostActions: SettingsHostActions
    ) {
        self.jsonStore = jsonStore
        self.catalog = catalog
        self.errorLog = errorLog
        self.hostActions = hostActions
    }

    var body: some View {
        Group {
            SettingsSectionHeader(
                String(localized: "settings.section.customCommands", defaultValue: "Custom Commands"),
                section: .keyboardShortcuts
            )
            .accessibilityIdentifier("SettingsCustomCommandShortcutsSection")

            SettingsCard {
                addRow
                let bound = sortedBoundCommandIds
                if !bound.isEmpty {
                    SettingsCardDivider()
                    ForEach(Array(bound.enumerated()), id: \.element) { index, commandId in
                        boundRow(commandId)
                        if index < bound.count - 1 {
                            SettingsCardDivider()
                        }
                    }
                }
            }
            .settingsSearchAnchors(["setting:keyboardShortcuts:customCommands"])

            Text(String(
                localized: "settings.customCommands.hint",
                defaultValue: "Bind a single keystroke to any Command Palette command. The shortcut fires on the focused window; commands unavailable in the current context do nothing."
            ))
            .cmuxFont(.caption)
            .foregroundColor(.secondary)
            .padding(.leading, 2)
            .accessibilityIdentifier("CustomCommandShortcutsHint")
        }
        .task { await streamCommandShortcuts() }
        .task { await streamActionBindings() }
        .onAppear { reloadCatalogIfNeeded() }
        .onDisappear {
            commandStreamTask?.cancel()
            bindingStreamTask?.cancel()
        }
        .sheet(isPresented: $isPickerPresented) {
            CommandShortcutPickerSheet(
                search: { hostActions.searchCommandShortcutCatalog(query: $0, limit: 60) },
                alreadyBoundCommandIds: Set(commandShortcuts.keys),
                conflictLabel: { stroke, excluding in
                    commandShortcutConflictLabel(
                        stroke: stroke,
                        excludingCommandId: excluding,
                        actionBindings: actionBindings,
                        commandShortcuts: commandShortcuts,
                        title: title(for:)
                    )
                },
                onAssign: { commandId, shortcut in
                    Task { await assign(shortcut, to: commandId) }
                }
            )
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private var addRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:keyboardShortcuts:customCommands:add",
            String(localized: "settings.customCommands.add.title", defaultValue: "Command Shortcuts"),
            subtitle: String(
                localized: "settings.customCommands.add.subtitle",
                defaultValue: "Search the Command Palette and assign a keystroke."
            )
        ) {
            Button {
                isPickerPresented = true
            } label: {
                Label(
                    String(localized: "settings.customCommands.add.button", defaultValue: "Add Shortcut"),
                    systemImage: "plus"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("CustomCommandShortcutsAddButton")
        }
    }

    @ViewBuilder
    private func boundRow(_ commandId: String) -> some View {
        let shortcut = commandShortcuts[commandId]
        let bareKeyRejected = rowBareKeyRejections.contains(commandId)
        let conflict = rowConflicts[commandId]
        let validationMessage: String? = {
            if bareKeyRejected {
                return String(
                    localized: "shortcut.recorder.error.bareKeyNotAllowed",
                    defaultValue: "Shortcuts must include ⌘ ⌥ ⌃ or ⇧"
                )
            }
            if let conflict {
                let messageFormat = String(
                    localized: "shortcut.recorder.error.conflictsWithAction",
                    defaultValue: "This shortcut conflicts with %@ (%@)."
                )
                return String.localizedStringWithFormat(messageFormat, conflict, "")
            }
            return nil
        }()

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: commandId))
                    Text(commandId)
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ShortcutRecorderView(
                    placeholder: shortcut.map { shortcutDisplayString($0, numbered: false) }
                        ?? String(localized: "shortcut.unbound.displayValue", defaultValue: "None"),
                    hasPendingRejection: bareKeyRejected,
                    firstStrokeRequiresModifier: true,
                    onStroke: { stroke in Task { await reassign(stroke: stroke, to: commandId) } },
                    onBareKeyRejected: { rowBareKeyRejections.insert(commandId) }
                )
                .frame(width: 160)

                Button {
                    rowBareKeyRejections.remove(commandId)
                    rowConflicts.removeValue(forKey: commandId)
                    Task { await remove(commandId) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "shortcut.recorder.clear.help", defaultValue: "Unbind shortcut"))
                .accessibilityLabel(String(localized: "shortcut.recorder.clear", defaultValue: "Unbind"))
                .accessibilityIdentifier("CustomCommandShortcutRemoveButton")
            }

            if let validationMessage {
                ShortcutValidationBanner(message: validationMessage) {
                    rowBareKeyRejections.remove(commandId)
                    rowConflicts.removeValue(forKey: commandId)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Data

    private var sortedBoundCommandIds: [String] {
        commandShortcuts.keys
            .filter { !(commandShortcuts[$0]?.isUnbound ?? true) }
            .sorted { title(for: $0).localizedCaseInsensitiveCompare(title(for: $1)) == .orderedAscending }
    }

    private func title(for commandId: String) -> String {
        catalogEntries.first { $0.commandId == commandId }?.title ?? commandId
    }

    private func reloadCatalogIfNeeded() {
        if catalogEntries.isEmpty {
            catalogEntries = hostActions.commandShortcutCatalog()
        }
    }

    private func streamCommandShortcuts() async {
        commandStreamTask?.cancel()
        let task = Task {
            for await dictionary in jsonStore.values(for: catalog.shortcuts.commands) {
                if Task.isCancelled { break }
                commandShortcuts = dictionary
                // An external cmux.json edit that resolves a row cleanly should
                // dismiss any stale banner for that command.
                pruneStaleRejections()
            }
        }
        commandStreamTask = task
        await task.value
    }

    private func streamActionBindings() async {
        bindingStreamTask?.cancel()
        let task = Task {
            for await dictionary in jsonStore.values(for: catalog.shortcuts.bindings) {
                if Task.isCancelled { break }
                actionBindings = dictionary
            }
        }
        bindingStreamTask = task
        await task.value
    }

    private func pruneStaleRejections() {
        for commandId in Array(rowConflicts.keys) where commandShortcuts[commandId] == nil {
            rowConflicts.removeValue(forKey: commandId)
        }
        for commandId in Array(rowBareKeyRejections) where commandShortcuts[commandId] != nil {
            rowBareKeyRejections.remove(commandId)
        }
    }

    /// Re-records an existing bound command's shortcut, applying the same
    /// conflict check as the picker.
    private func reassign(stroke: ShortcutStroke, to commandId: String) async {
        let proposed = StoredShortcut(first: stroke)
        if let conflict = commandShortcutConflictLabel(
            stroke: proposed,
            excludingCommandId: commandId,
            actionBindings: actionBindings,
            commandShortcuts: commandShortcuts,
            title: title(for:)
        ) {
            rowConflicts[commandId] = conflict
            rowBareKeyRejections.remove(commandId)
            return
        }
        rowConflicts.removeValue(forKey: commandId)
        rowBareKeyRejections.remove(commandId)
        await assign(proposed, to: commandId)
    }

    private func assign(_ shortcut: StoredShortcut, to commandId: String) async {
        var updated = commandShortcuts
        updated[commandId] = shortcut
        await write(updated)
    }

    private func remove(_ commandId: String) async {
        var updated = commandShortcuts
        updated.removeValue(forKey: commandId)
        await write(updated)
    }

    private func write(_ updated: [String: StoredShortcut]) async {
        do {
            try await jsonStore.set(updated, for: catalog.shortcuts.commands)
        } catch {
            errorLog.record(error, keyID: catalog.shortcuts.commands.id)
        }
    }
}

/// Red inline validation banner with an Undo affordance, matching the per-action
/// recorder rows. Factored out so the bound-command rows and any future
/// command-shortcut surface render an identical banner.
@MainActor
struct ShortcutValidationBanner: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .cmuxFont(.caption)
                .foregroundStyle(.red)
            Text(message)
                .cmuxFont(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "shortcut.recorder.undo", defaultValue: "Undo")) {
                onUndo()
            }
            .buttonStyle(.link)
            .cmuxFont(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.35), lineWidth: 1)
        }
        .accessibilityIdentifier("ShortcutRecorderValidationMessage")
    }
}

/// The label of the first existing binding a proposed command shortcut collides
/// with — a built-in action's display name or another command's title — or
/// `nil` when the keystroke is free. Built-in actions are checked with
/// numbered-digit family semantics so binding `⌃5` is blocked by the `⌃1…9`
/// workspace selector. The proposed command stroke is never a numbered family.
@MainActor
func commandShortcutConflictLabel(
    stroke: StoredShortcut,
    excludingCommandId: String?,
    actionBindings: [String: StoredShortcut],
    commandShortcuts: [String: StoredShortcut],
    title: (String) -> String
) -> String? {
    for action in ShortcutAction.allCases {
        let effective = actionBindings[action.rawValue] ?? action.defaultShortcut
        guard let effective, !effective.isUnbound else { continue }
        if numberedAwareStrokesConflict(
            stroke.first,
            numbered: false,
            effective.first,
            numbered: action.usesNumberedDigitMatching
        ) {
            return action.displayName
        }
    }
    for (commandId, existing) in commandShortcuts where commandId != excludingCommandId {
        guard !existing.isUnbound else { continue }
        if numberedAwareStrokesConflict(stroke.first, numbered: false, existing.first, numbered: false) {
            return title(commandId)
        }
    }
    return nil
}
