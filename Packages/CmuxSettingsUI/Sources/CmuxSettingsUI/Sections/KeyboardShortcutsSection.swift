import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Keyboard Shortcuts** section.
///
/// Lists every ``ShortcutAction`` grouped by ``ShortcutAction/Group``;
/// each row exposes a ``ShortcutRecorderView`` that captures a new
/// binding and persists it through the JSON-backed
/// ``KeyboardShortcutsCatalogSection/bindings`` dictionary.
///
/// Default bindings are intentionally not declared here — the legacy
/// `KeyboardShortcutSettings` defaults table is the source of truth for
/// "what should `nextSurface` map to out of the box" and stays in the
/// app target until its full migration. Rows that aren't user-bound
/// render `(default)` so users can see they'll inherit whatever the
/// runtime resolves.
public struct KeyboardShortcutsSection: View {
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog
    private let errorLog: SettingsErrorLog?

    @State private var bindings: [String: StoredShortcut] = [:]
    @State private var streamTask: Task<Void, Never>?

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
            ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
                Section(group.title) {
                    ForEach(actionsInGroup(group), id: \.self) { action in
                        actionRow(action)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await streamBindings() }
        .onDisappear { streamTask?.cancel() }
    }

    @ViewBuilder
    private func actionRow(_ action: ShortcutAction) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.displayName)
                Text(action.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ShortcutRecorderView(
                placeholder: bindings[action.rawValue].map(format) ?? "(default)",
                onStroke: { stroke in
                    Task { await assign(stroke: stroke, to: action) }
                }
            )
            .frame(width: 200, height: 28)
            Button("Clear") {
                Task { await clearBinding(for: action) }
            }
            .buttonStyle(.borderless)
            .disabled(bindings[action.rawValue] == nil)
        }
        .padding(.vertical, 2)
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

    private func clearBinding(for action: ShortcutAction) async {
        var updated = bindings
        updated.removeValue(forKey: action.rawValue)
        await write(updated)
    }

    private func write(_ updated: [String: StoredShortcut]) async {
        do {
            try await jsonStore.set(updated, for: catalog.shortcuts.bindings)
        } catch {
            errorLog?.record(error, keyID: catalog.shortcuts.bindings.id)
        }
    }
}
