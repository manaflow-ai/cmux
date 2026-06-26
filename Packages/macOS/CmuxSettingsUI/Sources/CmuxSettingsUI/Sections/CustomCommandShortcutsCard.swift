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
        // Read the built-in action bindings *fresh* at conflict-check time (only
        // on a record attempt, so cheap) rather than from a snapshot: the
        // per-action recorder rows on this same Settings page can rebind a
        // built-in mid-session, and a stale snapshot would let a command shadow
        // a just-rebound built-in (or keep blocking a just-freed key).
        CommandShortcutConflictChecker(
            actionBindings: hostActions.effectiveActionShortcuts(),
            configuredActionShortcuts: hostActions.configuredActionShortcuts(),
            commandShortcuts: commandShortcuts,
            title: title(for:)
        )
    }

    private func reloadCatalogIfNeeded() {
        if catalogEntries.isEmpty {
            catalogEntries = hostActions.commandShortcutCatalog()
        }
    }

    /// Loads the bound command shortcuts from the host's lenient parser (rather
    /// than the package's object-only typed decode, which is all-or-nothing and
    /// would drop a single string-form binding). Built-in action bindings, used
    /// only for conflict detection, are read fresh per check in
    /// ``conflictChecker()`` so a same-session rebind is never stale.
    private func seedFromHost() {
        commandShortcuts = hostActions.commandShortcuts()
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
        // Write an explicit unbind marker rather than deleting the key. The
        // settings resolver merges `shortcuts.commands` from fallback config
        // files (``fillMissingSettings``) and only suppresses a fallback binding
        // when the primary file has an entry for that command. Deleting the
        // primary entry would let a fallback-inherited shortcut reappear on the
        // next reload; the documented "none" marker is parsed as unbound, stays
        // schema-valid (unlike the unbound object form), and suppresses it.
        do {
            try await jsonStore.setMapEntry(
                CustomCommandShortcutsCard.unbindMarker,
                forKey: commandId,
                in: JSONKey<[String: String]>(id: catalog.shortcuts.commands.id, defaultValue: [:])
            )
            commandShortcuts.removeValue(forKey: commandId)
        } catch {
            errorLog.record(error, keyID: catalog.shortcuts.commands.id)
        }
    }

    /// The documented unbind marker written for a cleared command shortcut. A
    /// string (not the unbound object form) so it satisfies the schema and is
    /// parsed as ``StoredShortcut/unbound`` by the app's config reader.
    private static let unbindMarker = "none"
}
