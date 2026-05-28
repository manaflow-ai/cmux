import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Keyboard Shortcuts** section.
///
/// Lists every ``ShortcutAction`` grouped by ``ShortcutAction/Group``.
/// Each row exposes:
///
/// 1. The action's display name + dotted id.
/// 2. A ``ShortcutRecorderView`` showing the user's override or the
///    factory default (sourced from
///    ``ShortcutAction/defaultStroke``). Recording a new chord saves
///    it through the JSON-backed
///    ``KeyboardShortcutsCatalogSection/bindings`` dictionary.
/// 3. A `Reset to Default` button when the row has an override.
/// 4. A `Clear` button that explicitly unbinds the action.
/// 5. A red conflict warning when two different actions resolve to
///    the same effective stroke.
@MainActor
public struct KeyboardShortcutsSection: View {
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog
    private let errorLog: SettingsErrorLog?

    @State private var bindings: [String: StoredShortcut] = [:]
    @State private var streamTask: Task<Void, Never>?
    @State private var chordModeActions: Set<String> = []

    public init(
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog? = nil
    ) {
        self.jsonStore = jsonStore
        self.catalog = catalog
        self.errorLog = errorLog
    }

    public var body: some View {
        Form {
            Section {
                Text("Override any keyboard shortcut. Recordings persist to cmux.json and apply across all surfaces immediately. Conflicts (two actions on the same chord) are flagged in red.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
                Section(group.title) {
                    ForEach(actionsInGroup(group), id: \.self) { action in
                        actionRow(action)
                    }
                }
            }
            Section {
                Button(role: .destructive) {
                    Task { await resetAll() }
                } label: {
                    Label("Reset All Shortcuts to Default", systemImage: "arrow.counterclockwise")
                }
            } footer: {
                Text("Removes every user override so all rows fall back to their factory defaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await streamBindings() }
        .onDisappear { streamTask?.cancel() }
    }

    @ViewBuilder
    private func actionRow(_ action: ShortcutAction) -> some View {
        let override = bindings[action.rawValue]
        let effective = override ?? action.defaultStroke.map { StoredShortcut(first: $0) }
        let hasOverride = override != nil
        let conflict = effective.flatMap { detectConflict(for: action, stroke: $0) }

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.displayName)
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
                onStroke: { stroke in
                    Task { await assign(stroke: stroke, to: action) }
                },
                onChord: { chord in
                    Task { await assignChord(chord, to: action) }
                }
            )
            .frame(width: 220, height: 28)
            Toggle(isOn: Binding(
                get: { chordModeActions.contains(action.rawValue) },
                set: { isOn in
                    if isOn {
                        chordModeActions.insert(action.rawValue)
                    } else {
                        chordModeActions.remove(action.rawValue)
                    }
                }
            )) {
                Image(systemName: "circle.grid.cross.fill")
            }
            .toggleStyle(.button)
            .help("Record two-stroke chord (e.g. ⌃B then P)")
            if hasOverride {
                Button("Reset") {
                    Task { await resetToDefault(action: action) }
                }
                .buttonStyle(.borderless)
            } else {
                Button("Clear") {
                    Task { await clearBinding(for: action) }
                }
                .buttonStyle(.borderless)
                .disabled(bindings[action.rawValue] == nil && action.defaultStroke != nil)
            }
        }
        .padding(.vertical, 2)
    }

    private func formatPlaceholder(effective: StoredShortcut?, hasOverride: Bool) -> String {
        guard let effective else { return "(unbound)" }
        if effective.isUnbound { return "(unbound)" }
        let formatted = format(effective)
        return hasOverride ? formatted : "\(formatted) (default)"
    }

    private func detectConflict(for action: ShortcutAction, stroke: StoredShortcut) -> ShortcutAction? {
        // Walk every other action with a resolved effective stroke
        // and flag the first one whose first chord matches. Two
        // actions intentionally sharing a chord is rare; surfacing it
        // is cheap and helps users understand why one of two
        // overlapping shortcuts isn't firing.
        for other in ShortcutAction.allCases where other != action {
            let otherOverride = bindings[other.rawValue]
            let otherEffective = otherOverride ?? other.defaultStroke.map { StoredShortcut(first: $0) }
            guard let otherEffective, !otherEffective.isUnbound else { continue }
            if stroke.first == otherEffective.first {
                return other
            }
        }
        return nil
    }

    private func actionsInGroup(_ group: ShortcutAction.Group) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.group == group }
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
