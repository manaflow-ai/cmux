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

    /// Bound command shortcuts, read through the host's lenient config parser
    /// (see ``SettingsHostActions/commandShortcuts()``) so a binding written in
    /// string form `"cmd+n"` is resolved rather than dropped. Updated
    /// optimistically on each edit; the per-entry write is lossless regardless.
    @State private var commandShortcuts: [String: StoredShortcut] = [:]
    /// Effective built-in action bindings (override-or-default), read through the
    /// host's lenient resolver for conflict detection against built-in actions.
    @State private var actionBindings: [String: StoredShortcut] = [:]
    /// The full command catalog (id → title/subtitle/keywords), loaded once from
    /// the host so bound rows can resolve a command id back to a title.
    @State private var catalogEntries: [CommandShortcutCatalogEntry] = []

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
        .onAppear {
            reloadCatalogIfNeeded()
            seedFromHost()
        }
        .sheet(isPresented: $isPickerPresented) {
            CommandShortcutPickerSheet(
                search: { hostActions.searchCommandShortcutCatalog(query: $0, limit: 60) },
                alreadyBoundCommandIds: Set(commandShortcuts.keys),
                conflictLabel: { stroke, excluding in
                    conflictChecker().conflictLabel(stroke: stroke, excludingCommandId: excluding)
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
                    localized: "shortcut.recorder.error.conflictsWithBinding",
                    defaultValue: "This shortcut conflicts with %@."
                )
                return String.localizedStringWithFormat(messageFormat, conflict)
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

    private func conflictChecker() -> CommandShortcutConflictChecker {
        CommandShortcutConflictChecker(
            actionBindings: actionBindings,
            commandShortcuts: commandShortcuts,
            title: title(for:)
        )
    }

    private func reloadCatalogIfNeeded() {
        if catalogEntries.isEmpty {
            catalogEntries = hostActions.commandShortcutCatalog()
        }
    }

    /// Loads the bound command shortcuts and the effective built-in action
    /// bindings from the host's lenient parser. Both go through the host rather
    /// than the package's object-only typed decode, which is all-or-nothing and
    /// would drop a single string-form binding (blanking the whole map and
    /// bypassing conflict detection).
    private func seedFromHost() {
        commandShortcuts = hostActions.commandShortcuts()
        actionBindings = hostActions.effectiveActionShortcuts()
        pruneStaleRejections()
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
        if let conflict = conflictChecker().conflictLabel(stroke: proposed, excludingCommandId: commandId) {
            rowConflicts[commandId] = conflict
            rowBareKeyRejections.remove(commandId)
            return
        }
        rowConflicts.removeValue(forKey: commandId)
        rowBareKeyRejections.remove(commandId)
        await assign(proposed, to: commandId)
    }

    private func assign(_ shortcut: StoredShortcut, to commandId: String) async {
        // Per-entry write preserves every sibling's raw on-disk form (including
        // string-form bindings the package can't type-decode) instead of
        // replacing the whole map. Update local state optimistically; the host
        // re-seed on the next appear reconciles with the authoritative parse.
        do {
            try await jsonStore.setMapEntry(shortcut, forKey: commandId, in: catalog.shortcuts.commands)
            commandShortcuts[commandId] = shortcut
        } catch {
            errorLog.record(error, keyID: catalog.shortcuts.commands.id)
        }
    }

    private func remove(_ commandId: String) async {
        do {
            try await jsonStore.setMapEntry(
                StoredShortcut?.none,
                forKey: commandId,
                in: catalog.shortcuts.commands
            )
            commandShortcuts.removeValue(forKey: commandId)
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

/// Detects whether a proposed single-stroke command shortcut collides with an
/// existing built-in action binding or another command binding.
///
/// A value type constructed with the current bindings (rather than a free
/// function) so the conflict surface is owned, testable, and not ambient module
/// API. Built-in actions are checked with numbered-digit family semantics so
/// binding `⌃5` is blocked by the `⌃1…9` workspace selector; the proposed
/// command stroke is never itself a numbered family.
@MainActor
struct CommandShortcutConflictChecker {
    /// Built-in action overrides from `shortcuts.bindings`.
    let actionBindings: [String: StoredShortcut]
    /// Other commands' bindings from `shortcuts.commands`.
    let commandShortcuts: [String: StoredShortcut]
    /// Resolves a command id to its display title for the banner.
    let title: (String) -> String

    /// The display label of the first conflicting binding — a built-in action's
    /// display name or another command's title — or `nil` when `stroke` is free.
    /// Pass the command id being rebound as `excludingCommandId` so a command's
    /// own existing binding is not treated as a self-conflict.
    func conflictLabel(stroke: StoredShortcut, excludingCommandId: String?) -> String? {
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
}
