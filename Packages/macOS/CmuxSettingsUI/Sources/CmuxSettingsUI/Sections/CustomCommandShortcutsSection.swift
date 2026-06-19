import CmuxSettings
import SwiftUI

/// The result of checking a proposed custom-command shortcut for collisions.
public enum CustomCommandShortcutConflict: Equatable, Sendable {
    /// Collides with a built-in action's shortcut.
    case action
    /// Collides with another command's shortcut (the conflicting command id).
    case command(String)
}

/// First stroke of a currently-bound action, paired with whether that action
/// matches the whole `1…9` digit family. Numbered actions (e.g.
/// ``ShortcutAction/selectSurfaceByNumber``) normalize their stored key to the
/// `"1"` placeholder but consume every `⌘1`…`⌘9` / `⌃1`…`⌃9` keystroke at
/// runtime, so the flag must travel with the stroke for conflict detection to
/// see the overlap.
public struct ActionFirstStroke: Equatable, Sendable {
    public let stroke: ShortcutStroke
    public let numbered: Bool

    public init(stroke: ShortcutStroke, numbered: Bool) {
        self.stroke = stroke
        self.numbered = numbered
    }
}

/// Pure conflict check for a proposed custom-command shortcut: collides when its
/// first stroke equals an existing action first-stroke or another command's first
/// stroke. Commands are always-on, so no `when` nuance applies; numbered-digit
/// actions still consume their whole `1…9` family, so that flag is honored.
///
/// - Parameters:
///   - proposed: The shortcut being recorded.
///   - forCommandId: The command being bound (excluded from the command scan).
///   - existingCommandBindings: Current command bindings keyed by command id.
///   - actionFirstStrokes: First strokes of all currently-bound actions, each
///     tagged with its ``ShortcutAction/usesNumberedDigitMatching`` flag.
/// - Returns: The conflict, or `nil` when the stroke is free.
public func customCommandShortcutConflict(
    proposed: StoredShortcut,
    forCommandId: String,
    existingCommandBindings: [String: StoredShortcut],
    actionFirstStrokes: [ActionFirstStroke]
) -> CustomCommandShortcutConflict? {
    guard !proposed.isUnbound else { return nil }
    // Compare by key + modifiers ignoring `keyCode`: action defaults carry
    // `keyCode: nil` while recorded strokes carry a resolved keyCode, so a raw
    // `ShortcutStroke ==` would let a command silently shadow an action with the
    // same logical keystroke. Reuse the same keyCode-agnostic comparator the
    // action conflict path uses, carrying each action's numbered flag so a
    // command bound to e.g. ⌘5 is caught against the ⌘1…9 numbered family.
    if actionFirstStrokes.contains(where: {
        numberedAwareStrokesConflict($0.stroke, numbered: $0.numbered, proposed.first, numbered: false)
    }) {
        return .action
    }
    for (commandId, binding) in existingCommandBindings
    where commandId != forCommandId
        && !binding.isUnbound
        && numberedAwareStrokesConflict(binding.first, numbered: false, proposed.first, numbered: false) {
        return .command(commandId)
    }
    return nil
}

/// **Custom Commands** section — lets the user bind a keyboard shortcut to any
/// Command-Palette command that has no built-in action shortcut.
@MainActor
public struct CustomCommandShortcutsSection: View {
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog
    private let errorLog: SettingsErrorLog
    private let bindableCommandCatalog: any BindableCommandCatalogProviding

    @State private var bindings: [String: StoredShortcut] = [:]
    @State private var actionFirstStrokes: [ActionFirstStroke] = []
    @State private var titles: [String: String] = [:]
    @State private var streamTask: Task<Void, Never>?
    /// The loaded picker contents. Using `.sheet(item:)` (not
    /// `.sheet(isPresented:)` + separate state) couples the data and the
    /// presentation atomically, so the sheet never renders before the awaited
    /// command list is assigned.
    @State private var pickerPresentation: CommandPickerPresentation?
    /// Commands the user picked but has not yet recorded a stroke for. They
    /// surface as unbound rows so the user can click the recorder to assign a
    /// shortcut; cleared once a binding is written or the row is removed.
    @State private var pendingCommandIds: Set<String> = []
    @State private var conflictRejections: [String: CustomCommandShortcutConflict] = [:]

    public init(
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        bindableCommandCatalog: any BindableCommandCatalogProviding
    ) {
        self.jsonStore = jsonStore
        self.catalog = catalog
        self.errorLog = errorLog
        self.bindableCommandCatalog = bindableCommandCatalog
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(
                String(localized: "settings.section.customCommands", defaultValue: "Custom Commands"),
                section: .keyboardShortcuts
            )
            SettingsCard {
                addRow
                if visibleCommandIds.isEmpty {
                    SettingsCardDivider()
                    emptyStateRow
                } else {
                    ForEach(visibleCommandIds, id: \.self) { commandId in
                        SettingsCardDivider()
                        CustomCommandShortcutRow(
                            title: titles[commandId] ?? commandId,
                            commandId: commandId,
                            binding: bindings[commandId] ?? .unbound,
                            conflict: conflictRejections[commandId],
                            onStroke: { stroke in Task { await assign(StoredShortcut(first: stroke), to: commandId) } },
                            onRemove: { Task { await remove(commandId) } },
                            onDismissConflict: { conflictRejections.removeValue(forKey: commandId) }
                        )
                    }
                }
            }
            .settingsSearchAnchors(["setting:keyboardShortcuts:customCommands"])
        }
        .task { await streamBindings() }
        .task { await streamActionFirstStrokes() }
        .task { await loadCatalogTitles() }
        .onDisappear { streamTask?.cancel() }
        .sheet(item: $pickerPresentation) { presentation in
            CommandShortcutPickerSheet(
                commands: presentation.commands,
                onSelect: { descriptor in
                    pickerPresentation = nil
                    titles[descriptor.id] = descriptor.title
                    pendingCommandIds.insert(descriptor.id)
                },
                onCancel: { pickerPresentation = nil }
            )
        }
    }

    /// Bound commands plus any picked-but-not-yet-recorded commands, sorted by
    /// display title.
    private var visibleCommandIds: [String] {
        let bound = bindings.filter { !$0.value.isUnbound }.keys
        return Set(bound).union(pendingCommandIds).sorted {
            (titles[$0] ?? $0).localizedCaseInsensitiveCompare(titles[$1] ?? $1) == .orderedAscending
        }
    }

    @ViewBuilder
    private var addRow: some View {
        SettingsCardRow(
            configurationReview: .json("shortcuts.commands"),
            searchAnchorID: "setting:keyboardShortcuts:customCommands-add",
            String(localized: "settings.customCommands.title", defaultValue: "Command shortcuts"),
            subtitle: String(localized: "settings.customCommands.subtitle", defaultValue: "Assign your own keyboard shortcuts to commands from the Command Palette.")
        ) {
            Button {
                Task {
                    let loaded = await bindableCommandCatalog.bindableCommands()
                    let available = loaded.filter {
                        (bindings[$0.id]?.isUnbound ?? true) && !pendingCommandIds.contains($0.id)
                    }
                    pickerPresentation = CommandPickerPresentation(commands: available)
                }
            } label: {
                Label(
                    String(localized: "settings.customCommands.add", defaultValue: "Add Shortcut"),
                    systemImage: "plus"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("SettingsAddCustomCommandShortcutButton")
        }
    }

    @ViewBuilder
    private var emptyStateRow: some View {
        Text(String(localized: "settings.customCommands.empty", defaultValue: "No custom command shortcuts yet. Use Add Shortcut to bind one."))
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Resolves display titles for already-bound commands from the live command
    /// catalog. `shortcuts.commands` persists only `commandId → shortcut`, so on a
    /// fresh open (no picker selection this session) the rows would otherwise show
    /// the raw command id; this backfills `titles` so they render their real name.
    /// Picker-selected titles are kept — we only fill ids that lack a title.
    private func loadCatalogTitles() async {
        let loaded = await bindableCommandCatalog.bindableCommands()
        guard !loaded.isEmpty else { return }
        for descriptor in loaded where titles[descriptor.id] == nil {
            titles[descriptor.id] = descriptor.title
        }
    }

    private func streamBindings() async {
        streamTask?.cancel()
        let task = Task {
            for await dictionary in jsonStore.values(for: catalog.shortcuts.commands) {
                if Task.isCancelled { break }
                bindings = dictionary
                // A binding that resolved (externally edited cmux.json or just
                // recorded) is no longer pending, and a stale conflict banner
                // for a now-clean binding should clear.
                for (commandId, binding) in dictionary where !binding.isUnbound {
                    pendingCommandIds.remove(commandId)
                    conflictRejections.removeValue(forKey: commandId)
                }
            }
        }
        streamTask = task
        await task.value
    }

    private func streamActionFirstStrokes() async {
        for await actionBindings in jsonStore.values(for: catalog.shortcuts.bindings) {
            // Effective action strokes: explicit overrides plus declared defaults
            // for actions the user has not overridden.
            var strokes: [ActionFirstStroke] = []
            for action in ShortcutAction.allCases {
                let effective = actionBindings[action.rawValue] ?? action.defaultShortcut
                guard let effective, !effective.isUnbound else { continue }
                strokes.append(ActionFirstStroke(stroke: effective.first, numbered: action.usesNumberedDigitMatching))
            }
            actionFirstStrokes = strokes
        }
    }

    private func assign(_ shortcut: StoredShortcut, to commandId: String) async {
        if let conflict = customCommandShortcutConflict(
            proposed: shortcut,
            forCommandId: commandId,
            existingCommandBindings: bindings,
            actionFirstStrokes: actionFirstStrokes
        ) {
            conflictRejections[commandId] = conflict
            return
        }
        conflictRejections.removeValue(forKey: commandId)
        var updated = bindings
        updated[commandId] = shortcut
        // Clear the pending row only once the write is confirmed; a failed write
        // rolls back and leaves the row in place so the user can retry.
        if await write(updated) {
            pendingCommandIds.remove(commandId)
        }
    }

    private func remove(_ commandId: String) async {
        conflictRejections.removeValue(forKey: commandId)
        var updated = bindings
        updated.removeValue(forKey: commandId)
        if await write(updated) {
            pendingCommandIds.remove(commandId)
        }
    }

    /// Single authoritative mutation path for `shortcuts.commands`. Applies the
    /// new map to `bindings` optimistically before persisting so a rapid follow-up
    /// edit builds on the latest state (no lost update from reading the not-yet-
    /// streamed value), then rolls back to the prior snapshot if the write fails.
    /// The binding stream later reconciles `bindings` with the persisted file.
    @discardableResult
    private func write(_ updated: [String: StoredShortcut]) async -> Bool {
        let previous = bindings
        bindings = updated
        do {
            try await jsonStore.set(updated, for: catalog.shortcuts.commands)
            return true
        } catch {
            bindings = previous
            errorLog.record(error, keyID: catalog.shortcuts.commands.id)
            return false
        }
    }
}

/// Identifiable carrier for the command picker's contents, so the section can
/// drive `.sheet(item:)` — presentation and data are set together and the sheet
/// never shows a stale/empty list.
private struct CommandPickerPresentation: Identifiable {
    let id = UUID()
    let commands: [BindableCommandDescriptor]
}
