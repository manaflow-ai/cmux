import CmuxSettings
import SwiftUI

/// **Global Hotkey** section — mirrors the legacy in-app section:
/// one card with an Enable toggle and the system-wide chord recorder,
/// followed by a card note explaining macOS permissions.
///
/// The recorder reads and writes the same JSON-backed shortcut binding
/// the legacy app uses — `shortcuts.bindings["showHideAllWindows"]` —
/// so keystrokes persist immediately and round-trip with the rest of
/// the Keyboard Shortcuts section.
@MainActor
public struct GlobalHotkeySection: View {
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog
    private let errorLog: SettingsErrorLog

    @State private var enabled: DefaultsValueModel<Bool>
    @State private var bindings: [String: StoredShortcut] = [:]
    @State private var bindingsTask: Task<Void, Never>?
    @State private var restoreShortcut: StoredShortcut?

    private let hotkeyAction: ShortcutAction = .showHideAllWindows

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog
    ) {
        self.jsonStore = jsonStore
        self.catalog = catalog
        self.errorLog = errorLog
        _enabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.systemWideHotkeyEnabled))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.globalHotkey", defaultValue: "Global Hotkey"), section: .globalHotkey)
                .accessibilityIdentifier("SettingsGlobalHotkeySection")
            mainCard
            SettingsCardNote(
                String(localized: "settings.globalHotkey.note", defaultValue: "Use Command, Option, or Control with another key. No extra macOS permission is required.")
            )
            .accessibilityIdentifier("SettingsGlobalHotkeyNote")
        }
        .task {
            enabled.startObserving()
            await streamBindings()
        }
        .onDisappear { bindingsTask?.cancel() }
    }

    @ViewBuilder
    private var mainCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:globalHotkey:enable-hotkey",
                String(localized: "settings.globalHotkey.enable", defaultValue: "Enable System-Wide Hotkey"),
                subtitle: enabled.current
                    ? String(localized: "settings.globalHotkey.enable.subtitleOn", defaultValue: "Press the shortcut from any app to show or hide all cmux windows.")
                    : String(localized: "settings.globalHotkey.enable.subtitleOff", defaultValue: "Turn this on to show or hide all cmux windows from any app.")
            ) {
                Toggle("", isOn: Binding(get: { enabled.current }, set: { enabled.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsGlobalHotkeyToggle")
            }
            SettingsCardDivider()
            recorderRow
                .settingsSearchAnchors(["setting:globalHotkey:shortcut"])
        }
    }

    @ViewBuilder
    private var recorderRow: some View {
        let effective = currentShortcut
        let isUnbound = effective?.isUnbound ?? true
        let canRestore = isUnbound && restoreShortcut != nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "settings.globalHotkey.shortcut", defaultValue: "Show/Hide All Windows"))
                }
                Spacer()
                ShortcutRecorderView(
                    placeholder: placeholderText(for: effective)
                ) { stroke in
                    Task { await assign(stroke: stroke) }
                }
                .frame(width: 160)
                .accessibilityIdentifier("SettingsGlobalHotkeyRecorder")

                Button {
                    if canRestore, let restore = restoreShortcut {
                        Task { await write(updating: restore) }
                        restoreShortcut = nil
                    } else if let effective, !effective.isUnbound {
                        restoreShortcut = effective
                        Task { await write(updating: .unbound) }
                    }
                } label: {
                    Image(systemName: canRestore ? "arrow.counterclockwise.circle.fill" : "xmark.circle.fill")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .disabled(isUnbound && !canRestore)
                .help(
                    canRestore
                        ? String(localized: "shortcut.recorder.restore.help", defaultValue: "Restore previous shortcut")
                        : String(localized: "shortcut.recorder.clear.help", defaultValue: "Unbind shortcut")
                )
                .accessibilityLabel(
                    canRestore
                        ? String(localized: "shortcut.recorder.restore", defaultValue: "Restore")
                        : String(localized: "shortcut.recorder.clear", defaultValue: "Unbind")
                )
                .accessibilityIdentifier("ShortcutRecorderClearRestoreButton")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func write(updating shortcut: StoredShortcut) async {
        var updated = bindings
        updated[hotkeyAction.rawValue] = shortcut
        await write(updated)
    }

    private var currentShortcut: StoredShortcut? {
        if let override = bindings[hotkeyAction.rawValue] { return override }
        return hotkeyAction.defaultStroke.map { StoredShortcut(first: $0) }
    }

    private func placeholderText(for shortcut: StoredShortcut?) -> String {
        guard let shortcut, !shortcut.isUnbound else {
            // Matches the legacy recorder's unbound resting label.
            return String(localized: "shortcut.unbound.displayValue", defaultValue: "None")
        }
        // The global hotkey is always a single, non-numbered stroke, so the
        // shared formatter renders it directly. See ``shortcutDisplayString(_:numbered:)``.
        return shortcutStrokeDisplayString(shortcut.first)
    }

    private func streamBindings() async {
        bindingsTask?.cancel()
        let task = Task {
            for await dictionary in jsonStore.values(for: catalog.shortcuts.bindings) {
                if Task.isCancelled { break }
                bindings = dictionary
            }
        }
        bindingsTask = task
        await task.value
    }

    private func assign(stroke: ShortcutStroke) async {
        var updated = bindings
        updated[hotkeyAction.rawValue] = StoredShortcut(first: stroke)
        await write(updated)
    }

    private func write(_ updated: [String: StoredShortcut]) async {
        do {
            try await jsonStore.set(updated, for: catalog.shortcuts.bindings)
        } catch {
            errorLog.record(error, keyID: catalog.shortcuts.bindings.id)
        }
    }
}
