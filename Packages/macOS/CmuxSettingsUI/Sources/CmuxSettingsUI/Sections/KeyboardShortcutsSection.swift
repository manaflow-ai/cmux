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
    @State private var paneResizeStep: DefaultsValueModel<Int>

    /// Creates the keyboard shortcut editor with both current and compatibility stores.
    ///
    /// - Parameters:
    ///   - jsonStore: The authoritative `cmux.json` settings store.
    ///   - userDefaultsStore: The store containing compatibility shortcut overrides, or `nil`
    ///     to preserve the pre-compatibility behavior for existing package consumers.
    ///   - catalog: The settings key catalog shared with the stores.
    ///   - errorLog: The error sink for failed JSON writes.
    ///   - hostActions: Host callbacks for opening the external configuration editor.
    ///   - defaultShortcutResolver: Host-scoped factory defaults for dynamic actions.
    public init(
        jsonStore: JSONConfigStore,
        userDefaultsStore: UserDefaultsSettingsStore? = nil,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        hostActions: SettingsHostActions,
        defaultShortcutResolver: ShortcutDefaultResolver = .builtIn
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
            defaultShortcutResolver: defaultShortcutResolver,
            onShortcutsChanged: { hostActions.notifyShortcutSettingsDidChange() }
        ))
        _paneResizeStep = State(initialValue: DefaultsValueModel(
            store: userDefaultsStore ?? UserDefaultsSettingsStore(defaults: .standard),
            key: catalog.app.paneResizeStepPixels
        ))
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
                paneResizeStepRow
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
        .task {
            model.startObserving()
            paneResizeStep.startObserving()
        }
    }

    @ViewBuilder
    private var paneResizeStepRow: some View {
        SettingsCardRow(
            configurationReview: .json("app.paneResizeStepPixels"),
            searchAnchorID: "setting:keyboardShortcuts:pane-resize-step",
            String(localized: "settings.shortcuts.paneResizeStep", defaultValue: "Pane Resize Step"),
            subtitle: String(localized: "settings.shortcuts.paneResizeStep.subtitle", defaultValue: "Pixels moved each time a pane-resize shortcut repeats."),
            controlWidth: 196
        ) {
            Stepper(
                value: Binding(
                    get: { PaneResizeStepSettings.normalizedPixels(paneResizeStep.current) },
                    set: { paneResizeStep.set(PaneResizeStepSettings.normalizedPixels($0)) }
                ),
                in: PaneResizeStepSettings.minimumPixels...PaneResizeStepSettings.maximumPixels
            ) {
                Text(
                    String(
                        format: String(localized: "settings.shortcuts.paneResizeStep.value", defaultValue: "%d px"),
                        PaneResizeStepSettings.normalizedPixels(paneResizeStep.current)
                    )
                )
                .monospacedDigit()
                .frame(minWidth: 56, alignment: .trailing)
            }
            .controlSize(.small)
            .accessibilityIdentifier("SettingsPaneResizeStepStepper")
            .accessibilityLabel(String(localized: "settings.shortcuts.paneResizeStep", defaultValue: "Pane Resize Step"))
        }
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
