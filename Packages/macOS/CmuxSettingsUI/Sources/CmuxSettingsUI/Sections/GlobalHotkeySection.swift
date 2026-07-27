import CmuxSettings
import SwiftUI

/// **Global Hotkey** section — mirrors the legacy in-app section:
/// one card with an Enable toggle and the system-wide chord recorder,
/// followed by a card note explaining macOS permissions.
///
/// The recorder uses the shared shortcut model, so its effective value follows
/// runtime precedence and successful JSON writes retire legacy overrides.
@MainActor
public struct GlobalHotkeySection: View {
    @State private var enabled: DefaultsValueModel<Bool>
    @State private var shortcutModel: ShortcutListModel

    private let hotkeyAction: ShortcutAction = .showHideAllWindows

    /// Creates the global-hotkey editor with the shared shortcut persistence path.
    ///
    /// - Parameters:
    ///   - defaultsStore: Stores the enabled flag and legacy shortcut override.
    ///   - jsonStore: Stores authoritative shortcut bindings.
    ///   - catalog: The settings key catalog shared by both stores.
    ///   - errorLog: Records persistence failures.
    ///   - hostActions: Invalidates host-owned shortcut caches after successful writes.
    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        hostActions: SettingsHostActions = NoopSettingsHostActions()
    ) {
        _enabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.systemWideHotkeyEnabled))
        _shortcutModel = State(initialValue: ShortcutListModel(
            jsonStore: jsonStore,
            userDefaultsStore: defaultsStore,
            catalog: catalog,
            errorLog: errorLog,
            onShortcutsChanged: { hostActions.notifyShortcutSettingsDidChange() }
        ))
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
            shortcutModel.startObserving()
        }
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
        let effective = shortcutModel.effective(for: hotkeyAction)
        ShortcutListRowView(
            snapshot: ShortcutListRowSnapshot(
                action: hotkeyAction,
                isLast: true,
                title: String(localized: "settings.globalHotkey.shortcut", defaultValue: "Show/Hide All Windows"),
                subtitle: nil,
                placeholder: shortcutModel.formatPlaceholder(effective: effective, numbered: false),
                chordsEnabled: false,
                hasPendingRejection: shortcutModel.bareKeyRejections.contains(hotkeyAction.rawValue),
                firstStrokeRequiresModifier: true,
                isUnbound: effective?.isUnbound ?? true,
                canRestore: shortcutModel.canRestore(for: hotkeyAction),
                validationMessage: shortcutModel.validationMessage(for: hotkeyAction),
                recorderAccessibilityIdentifier: "SettingsGlobalHotkeyRecorder"
            ),
            actions: ShortcutListRowActions(
                onStroke: { stroke in Task { await shortcutModel.assign(stroke: stroke, to: hotkeyAction) } },
                onChord: { _ in },
                onBareKeyRejected: { shortcutModel.markBareKeyRejected(hotkeyAction) },
                onClearOrRestore: { Task { await shortcutModel.clearOrRestore(for: hotkeyAction) } },
                onClearRejections: { shortcutModel.clearRejections(for: hotkeyAction) }
            )
        )
        .equatable()
    }
}
