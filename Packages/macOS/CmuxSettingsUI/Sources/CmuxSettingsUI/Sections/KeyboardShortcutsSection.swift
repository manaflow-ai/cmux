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

    /// Creates the keyboard shortcut editor with both current and compatibility stores.
    ///
    /// - Parameters:
    ///   - jsonStore: The authoritative `cmux.json` settings store.
    ///   - userDefaultsStore: The store containing compatibility shortcut overrides, or `nil`
    ///     to preserve the pre-compatibility behavior for existing package consumers.
    ///   - catalog: The settings key catalog shared with the stores.
    ///   - errorLog: The error sink for failed JSON writes.
    ///   - hostActions: Host callbacks for opening the external configuration editor.
    public init(
        jsonStore: JSONConfigStore,
        userDefaultsStore: UserDefaultsSettingsStore? = nil,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        hostActions: SettingsHostActions
    ) {
        self.hostActions = hostActions
        _model = State(initialValue: ShortcutListModel(
            jsonStore: jsonStore,
            userDefaultsStore: userDefaultsStore,
            catalog: catalog,
            errorLog: errorLog,
            canRegisterSystemWideHotkey: {
                hostActions.canRegisterSystemWideHotkey($0)
            },
            onShortcutsChanged: { hostActions.notifyShortcutSettingsDidChange() }
        ))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"), section: .keyboardShortcuts)
                .accessibilityIdentifier("SettingsKeyboardShortcutsSection")
            SettingsCard {
                prefixRow
                SettingsCardDivider()
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
    private var prefixRow: some View {
        let prefix = model.prefix
        SettingsCardRow(
            configurationReview: .json("shortcuts.prefix"),
            searchAnchorID: "setting:keyboardShortcuts:prefix",
            String(localized: "settings.shortcuts.prefix", defaultValue: "Prefix Key"),
            subtitle: String(localized: "settings.shortcuts.prefix.subtitle", defaultValue: "Optional leader key for cmux shortcut chords. Leave it unbound to keep the terminal behavior unchanged.")
        ) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ShortcutRecorderView(
                        placeholder: model.formatPlaceholder(effective: prefix, numbered: false),
                        // The shared prefix policy permits bare Space as the
                        // tmux-style leader while still rejecting every other
                        // printable key at the model boundary.
                        hasPendingRejection: model.prefixRejection != nil,
                        firstStrokeRequiresModifier: false,
                        onStroke: { stroke in Task { await model.assignPrefix(stroke) } },
                        onBareKeyRejected: {}
                    )
                    .frame(width: 160)
                    .accessibilityIdentifier("ShortcutPrefixRecorder")

                    Button {
                        Task { await model.clearPrefix() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.medium)
                    }
                    .buttonStyle(.borderless)
                    .disabled(prefix.isUnbound)
                    .help(String(localized: "shortcut.prefix.clear.help", defaultValue: "Disable prefix key"))
                    .accessibilityLabel(String(localized: "shortcut.prefix.clear", defaultValue: "Disable prefix key"))
                    .accessibilityIdentifier("ShortcutPrefixClearButton")
                }

                if let message = model.prefixValidationMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .cmuxFont(.caption)
                            .foregroundStyle(.red)
                        Text(message)
                            .cmuxFont(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(String(localized: "shortcut.recorder.undo", defaultValue: "Undo")) {
                            model.clearPrefixRejection()
                        }
                        .buttonStyle(.link)
                        .cmuxFont(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red.opacity(0.12))
                    }
                    .accessibilityIdentifier("ShortcutPrefixValidationMessage")
                }
            }
        }
    }

    @ViewBuilder
    private var chordsRow: some View {
        let subtitle = model.prefix.isUnbound
            ? String(localized: "settings.shortcuts.chords.subtitle", defaultValue: "Choose Chord beside an action to record a two-step shortcut.")
            : String(localized: "settings.shortcuts.chords.subtitle.withPrefix", defaultValue: "Choose Chord beside an action, then press its second key; the configured prefix is included automatically.")
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:keyboardShortcuts:shortcut-chords",
            String(localized: "settings.shortcuts.chords", defaultValue: "Shortcut Chords"),
            subtitle: subtitle
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
