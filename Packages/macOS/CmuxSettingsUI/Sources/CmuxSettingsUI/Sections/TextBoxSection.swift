import CmuxFoundation
import CmuxSettings
import Foundation
import SwiftUI

/// **TextBox** section — controls for the rich terminal input.
@MainActor
public struct TextBoxSection: View {
    @State private var showOnNewTerminals: DefaultsValueModel<Bool>
    @State private var focusOnNewTerminals: DefaultsValueModel<Bool>
    @State private var maxLines: DefaultsValueModel<Int>
    @State private var defaultSubmitAction: DefaultsValueModel<String>
    @State private var submitActions: DefaultsValueModel<String>

    /// Creates the TextBox settings section.
    ///
    /// - Parameters:
    ///   - defaultsStore: The store used to read and write TextBox settings.
    ///   - catalog: The catalog that provides the TextBox-related setting keys.
    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _showOnNewTerminals = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.showTextBoxOnNewTerminals))
        _focusOnNewTerminals = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.focusTextBoxOnNewTerminals))
        _maxLines = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.textBoxMaxLines))
        _defaultSubmitAction = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.textBoxDefaultSubmitAction))
        _submitActions = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.textBoxSubmitActions))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.textBox", defaultValue: "TextBox"), section: .textBox)
            SettingsCard {
                showOnNewTerminalsRow
                SettingsCardDivider()
                focusOnNewTerminalsRow
                SettingsCardDivider()
                defaultSubmitActionRow
                SettingsCardDivider()
                maxLinesRow
            }
        }
        .task { startObservingSettings() }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            showOnNewTerminals,
            focusOnNewTerminals,
            defaultSubmitAction,
            submitActions,
            maxLines,
        ]
        models.forEach { $0.startObserving() }
    }

    @ViewBuilder
    private var showOnNewTerminalsRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.showTextBoxOnNewTerminals"),
            String(localized: "settings.textBox.showOnNewTerminals", defaultValue: "Show TextBox on New Terminals"),
            subtitle: String(localized: "settings.textBox.showOnNewTerminals.subtitle", defaultValue: "Opening a terminal tab, split, or workspace shows the TextBox.")
        ) {
            Toggle("", isOn: Binding(get: { showOnNewTerminals.current }, set: { showOnNewTerminals.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTextBoxShowOnNewTerminalsToggle")
                .accessibilityLabel(
                    String(localized: "settings.textBox.showOnNewTerminals", defaultValue: "Show TextBox on New Terminals")
                )
        }
    }

    @ViewBuilder
    private var focusOnNewTerminalsRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.focusTextBoxOnNewTerminals"),
            String(localized: "settings.textBox.focusOnNewTerminals", defaultValue: "Focus TextBox on New Terminals"),
            subtitle: String(localized: "settings.textBox.focusOnNewTerminals.subtitle", defaultValue: "Opening a terminal tab, split, or workspace puts keyboard focus in the TextBox.")
        ) {
            Toggle("", isOn: Binding(get: { focusOnNewTerminals.current }, set: { focusOnNewTerminals.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTextBoxFocusOnNewTerminalsToggle")
                .accessibilityLabel(
                    String(localized: "settings.textBox.focusOnNewTerminals", defaultValue: "Focus TextBox on New Terminals")
                )
        }
    }

    @ViewBuilder
    private var defaultSubmitActionRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.textBoxDefaultSubmitAction"),
            String(localized: "settings.textBox.defaultSubmitAction", defaultValue: "Default Submit Action"),
            subtitle: String(localized: "settings.textBox.defaultSubmitAction.subtitle", defaultValue: "Used for new terminal sessions. Active Claude, Codex, OpenCode, and Pi sessions always submit as text entry."),
            controlWidth: 210
        ) {
            Picker("", selection: Binding(get: { defaultSubmitAction.current }, set: { defaultSubmitAction.set($0) })) {
                ForEach(defaultSubmitActionOptions) { option in
                    Text(verbatim: option.title).tag(option.id)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("SettingsTextBoxDefaultSubmitActionPicker")
            .accessibilityLabel(
                String(localized: "settings.textBox.defaultSubmitAction", defaultValue: "Default Submit Action")
            )
        }
    }

    private var defaultSubmitActionOptions: [TextBoxSettingsSubmitActionOption] {
        TextBoxSettingsSubmitActionOptions().normalizedOptions(
            configuredJSON: submitActions.current,
            currentID: defaultSubmitAction.current
        )
    }

    @ViewBuilder
    private var maxLinesRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.textBoxMaxLines"),
            String(localized: "settings.textBox.maxLines", defaultValue: "TextBox Max Lines"),
            subtitle: String(localized: "settings.textBox.maxLines.subtitle", defaultValue: "Limits how tall the rich terminal input can grow before it scrolls."),
            controlWidth: 196
        ) {
            Stepper(
                value: Binding(get: { maxLines.current }, set: { maxLines.set($0) }),
                in: 1...20
            ) {
                Text(verbatim: "\(maxLines.current)")
                    .monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
            }
            .controlSize(.small)
            .accessibilityIdentifier("SettingsTextBoxMaxLinesStepper")
            .accessibilityLabel(
                String(localized: "settings.textBox.maxLines", defaultValue: "TextBox Max Lines")
            )
        }
    }
}
