import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Keyboard Shortcuts** section — mirrors the legacy in-app
/// section: one `SettingsCard` containing the chord docs link,
/// the Reset Defaults action, and a per-action recorder row for
/// every `ShortcutAction` (using the new package recorder).
@MainActor
public struct KeyboardShortcutsSection: View {
    private let hostActions: SettingsHostActions
    @State private var model: ShortcutListModel

    public init(
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        hostActions: SettingsHostActions
    ) {
        self.hostActions = hostActions
        _model = State(initialValue: ShortcutListModel(jsonStore: jsonStore, catalog: catalog, errorLog: errorLog))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"), section: .keyboardShortcuts)
                .accessibilityIdentifier("SettingsKeyboardShortcutsSection")
            SettingsCard {
                chordsRow
                SettingsCardDivider()
                ModifierHoldHintsSettingsRow()
                SettingsCardDivider()
                resetDefaultsRow
                SettingsCardDivider()
                ShortcutListStableLazyView(model: model)
            }
            .settingsSearchAnchors(["setting:keyboardShortcuts:shortcuts"])
            Text(String(localized: "settings.shortcuts.recordHint", defaultValue: "Click a shortcut value to record. Use X to unbind; it changes to restore after a clear."))
                .cmuxFont(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 2)
                .accessibilityIdentifier("ShortcutRecordingHint")
        }
        .task { model.startObserving() }
    }

    @ViewBuilder
    private var chordsRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:keyboardShortcuts:shortcut-chords",
            String(localized: "settings.shortcuts.chords", defaultValue: "Shortcut Chords"),
            subtitle: String(localized: "settings.shortcuts.chords.subtitle", defaultValue: "Add tmux-style multi-step shortcuts in cmux.json, for example [\"ctrl+b\", \"c\"].")
        ) {
            HStack(spacing: 8) {
                Link(
                    String(localized: "settings.shortcuts.chords.docsButton", defaultValue: "Chord docs"),
                    destination: URL(string: "https://cmux.com/docs/keyboard-shortcuts#shortcut-chords")!
                )
                .cmuxFont(.caption)
                .accessibilityIdentifier("SettingsKeyboardShortcutsChordDocsLink")

                Button(String(localized: "settings.app.settingsFile.openButton", defaultValue: "Open cmux.json")) {
                    hostActions.openConfigInExternalEditor()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsKeyboardShortcutsOpenSettingsFileButton")
            }
        }
    }

    @ViewBuilder
    private var resetDefaultsRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:keyboardShortcuts:reset-defaults",
            String(localized: "settings.shortcuts.resetDefaults", defaultValue: "Reset Default Shortcuts"),
            subtitle: String(localized: "settings.shortcuts.resetDefaults.subtitle", defaultValue: "Restore built-in shortcut values for shortcuts managed in app settings.")
        ) {
            Button {
                Task { await model.resetAll() }
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
}
