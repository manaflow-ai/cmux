import CmuxSettings
import SwiftUI

/// **Keyboard Shortcuts** section — mirrors the legacy in-app
/// section: one `SettingsCard` containing the chord docs link,
/// the Reset Defaults action, and a per-action recorder row for
/// every `ShortcutAction` (using the new package recorder).
@MainActor
public struct KeyboardShortcutsSection: View {
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog
    private let errorLog: SettingsErrorLog?
    private let hostActions: SettingsHostActions?

    @State private var bindings: [String: StoredShortcut] = [:]
    @State private var streamTask: Task<Void, Never>?
    @State private var chordModeActions: Set<String> = []

    public init(
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog? = nil,
        hostActions: SettingsHostActions? = nil
    ) {
        self.jsonStore = jsonStore
        self.catalog = catalog
        self.errorLog = errorLog
        self.hostActions = hostActions
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"))
                .accessibilityIdentifier("SettingsKeyboardShortcutsSection")
            SettingsCard {
                chordsRow
                SettingsCardDivider()
                resetDefaultsRow
                SettingsCardDivider()
                let actions = ShortcutAction.allCases
                ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                    actionRow(action)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    if index < actions.count - 1 {
                        SettingsCardDivider()
                    }
                }
            }
            Text(String(localized: "settings.shortcuts.recordHint", defaultValue: "Click a shortcut value to record. Use X to unbind; it changes to restore after a clear."))
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 2)
                .accessibilityIdentifier("ShortcutRecordingHint")
        }
        .task { await streamBindings() }
        .onDisappear { streamTask?.cancel() }
    }

    @ViewBuilder
    private var chordsRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            String(localized: "settings.shortcuts.chords", defaultValue: "Shortcut Chords"),
            subtitle: String(localized: "settings.shortcuts.chords.subtitle", defaultValue: "Add tmux-style multi-step shortcuts in cmux.json, for example [\"ctrl+b\", \"c\"].")
        ) {
            HStack(spacing: 8) {
                Link(
                    String(localized: "settings.shortcuts.chords.docsButton", defaultValue: "Chord docs"),
                    destination: URL(string: "https://cmux.sh/docs/configuration/keyboard-shortcuts")!
                )
                .font(.caption)
                .accessibilityIdentifier("SettingsKeyboardShortcutsChordDocsLink")

                if let hostActions {
                    Button(String(localized: "settings.app.settingsFile.openButton", defaultValue: "Open cmux.json")) {
                        hostActions.openConfigInExternalEditor()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsKeyboardShortcutsOpenSettingsFileButton")
                }
            }
        }
    }

    @ViewBuilder
    private var resetDefaultsRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            String(localized: "settings.shortcuts.resetDefaults", defaultValue: "Reset Default Shortcuts"),
            subtitle: String(localized: "settings.shortcuts.resetDefaults.subtitle", defaultValue: "Restore built-in shortcut values for shortcuts managed in app settings.")
        ) {
            Button {
                Task { await resetAll() }
            } label: {
                Label(
                    String(localized: "settings.shortcuts.resetDefaults.button", defaultValue: "Reset Defaults"),
                    systemImage: "arrow.counterclockwise"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("SettingsKeyboardShortcutsResetDefaultsButton")
        }
    }

    @ViewBuilder
    private func actionRow(_ action: ShortcutAction) -> some View {
        let override = bindings[action.rawValue]
        let effective = override ?? action.defaultStroke.map { StoredShortcut(first: $0) }
        let hasOverride = override != nil
        let conflict = effective.flatMap { detectConflict(for: action, stroke: $0) }

        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(action.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let conflict {
                    Text("Conflicts with \(conflict.displayName)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            ShortcutRecorderView(
                placeholder: formatPlaceholder(effective: effective, hasOverride: hasOverride),
                chordsEnabled: chordModeActions.contains(action.rawValue),
                onStroke: { stroke in Task { await assign(stroke: stroke, to: action) } },
                onChord: { chord in Task { await assignChord(chord, to: action) } }
            )
            .frame(width: 200, height: 26)
            Toggle(isOn: Binding(
                get: { chordModeActions.contains(action.rawValue) },
                set: { isOn in
                    if isOn { chordModeActions.insert(action.rawValue) }
                    else { chordModeActions.remove(action.rawValue) }
                }
            )) {
                Image(systemName: "circle.grid.cross.fill")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(String(localized: "settings.shortcuts.chord.toggleHelp", defaultValue: "Record two-stroke chord"))
            if hasOverride {
                Button(String(localized: "settings.shortcuts.row.reset", defaultValue: "Reset")) {
                    Task { await resetToDefault(action: action) }
                }
                .controlSize(.small)
            } else {
                Button(String(localized: "settings.shortcuts.row.clear", defaultValue: "Clear")) {
                    Task { await clearBinding(for: action) }
                }
                .controlSize(.small)
                .disabled(action.defaultStroke == nil && bindings[action.rawValue] == nil)
            }
        }
    }

    private func formatPlaceholder(effective: StoredShortcut?, hasOverride: Bool) -> String {
        guard let effective else { return "(unbound)" }
        if effective.isUnbound { return "(unbound)" }
        let formatted = format(effective)
        return hasOverride ? formatted : "\(formatted) (default)"
    }

    private func detectConflict(for action: ShortcutAction, stroke: StoredShortcut) -> ShortcutAction? {
        for other in ShortcutAction.allCases where other != action {
            let override = bindings[other.rawValue]
            let effective = override ?? other.defaultStroke.map { StoredShortcut(first: $0) }
            guard let effective, !effective.isUnbound else { continue }
            if stroke.first == effective.first { return other }
        }
        return nil
    }

    private func format(_ shortcut: StoredShortcut) -> String {
        if shortcut.isUnbound { return "(unbound)" }
        var parts: [String] = []
        if shortcut.first.control { parts.append("⌃") }
        if shortcut.first.option { parts.append("⌥") }
        if shortcut.first.shift { parts.append("⇧") }
        if shortcut.first.command { parts.append("⌘") }
        parts.append(shortcut.first.key.uppercased())
        if let chord = shortcut.second {
            parts.append(" ")
            if chord.control { parts.append("⌃") }
            if chord.option { parts.append("⌥") }
            if chord.shift { parts.append("⇧") }
            if chord.command { parts.append("⌘") }
            parts.append(chord.key.uppercased())
        }
        return parts.joined()
    }

    private func streamBindings() async {
        streamTask?.cancel()
        let task = Task {
            for await dictionary in jsonStore.values(for: catalog.shortcuts.bindings) {
                if Task.isCancelled { break }
                bindings = dictionary
            }
        }
        streamTask = task
        await task.value
    }

    private func assign(stroke: ShortcutStroke, to action: ShortcutAction) async {
        var updated = bindings
        updated[action.rawValue] = StoredShortcut(first: stroke)
        await write(updated)
    }

    private func assignChord(_ chord: StoredShortcut, to action: ShortcutAction) async {
        var updated = bindings
        updated[action.rawValue] = chord
        chordModeActions.remove(action.rawValue)
        await write(updated)
    }

    private func clearBinding(for action: ShortcutAction) async {
        var updated = bindings
        updated[action.rawValue] = StoredShortcut.unbound
        await write(updated)
    }

    private func resetToDefault(action: ShortcutAction) async {
        var updated = bindings
        updated.removeValue(forKey: action.rawValue)
        await write(updated)
    }

    private func resetAll() async {
        await write([:])
    }

    private func write(_ updated: [String: StoredShortcut]) async {
        do {
            try await jsonStore.set(updated, for: catalog.shortcuts.bindings)
        } catch {
            errorLog?.record(error, keyID: catalog.shortcuts.bindings.id)
        }
    }
}
