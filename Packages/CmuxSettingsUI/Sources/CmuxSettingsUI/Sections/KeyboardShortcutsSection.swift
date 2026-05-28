import CmuxSettings
import SwiftUI

/// **Keyboard Shortcuts** section. Mirrors the legacy chrome: header
/// per group, one `SettingsCard` per group containing all action
/// rows. Each row exposes the recorder, conflict text, reset / clear
/// buttons, and a per-row chord-mode toggle.
@MainActor
public struct KeyboardShortcutsSection: View {
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog
    private let errorLog: SettingsErrorLog?

    @State private var bindings: [String: StoredShortcut] = [:]
    @State private var streamTask: Task<Void, Never>?
    @State private var chordModeActions: Set<String> = []

    public init(jsonStore: JSONConfigStore, catalog: SettingCatalog, errorLog: SettingsErrorLog? = nil) {
        self.jsonStore = jsonStore
        self.catalog = catalog
        self.errorLog = errorLog
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionHeader("Keyboard Shortcuts")
            SettingsCard {
                SettingsCardRow(configurationReview: .action, "Customize Shortcuts",
                    subtitle: "Override any keyboard shortcut. Recordings persist to cmux.json and apply across all surfaces immediately. Conflicts are flagged in red.") {
                    Button(role: .destructive) {
                        Task { await resetAll() }
                    } label: {
                        Label("Reset All", systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                }
            }

            ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
                SettingsSectionHeader(group.title)
                SettingsCard {
                    let actions = ShortcutAction.allCases.filter { $0.group == group }
                    ForEach(Array(actions.enumerated()), id: \.element) { idx, action in
                        if idx > 0 { SettingsCardDivider() }
                        actionRow(action)
                    }
                }
            }
        }
        .task { await streamBindings() }
        .onDisappear { streamTask?.cancel() }
    }

    @ViewBuilder
    private func actionRow(_ action: ShortcutAction) -> some View {
        let override = bindings[action.rawValue]
        let effective = override ?? action.defaultStroke.map { StoredShortcut(first: $0) }
        let hasOverride = override != nil
        let conflict = effective.flatMap { detectConflict(for: action, stroke: $0) }

        SettingsCardRow(configurationReview: .json("shortcuts.bindings"), action.displayName,
            subtitle: conflict.map { "Conflicts with \($0.displayName)" } ?? action.rawValue
        ) {
            HStack(spacing: 6) {
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
                .help("Record two-stroke chord")
                if hasOverride {
                    Button("Reset") { Task { await resetToDefault(action: action) } }
                        .controlSize(.small)
                } else {
                    Button("Clear") { Task { await clearBinding(for: action) } }
                        .controlSize(.small)
                        .disabled(action.defaultStroke == nil && bindings[action.rawValue] == nil)
                }
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
