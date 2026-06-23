import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **TextBox** section — beta controls for the rich terminal input.
@MainActor
public struct TextBoxSection: View {
    @State private var showOnNewTerminals: DefaultsValueModel<Bool>
    @State private var focusOnNewTerminals: DefaultsValueModel<Bool>
    @State private var maxLines: DefaultsValueModel<Int>

    /// Creates the TextBox settings section.
    ///
    /// - Parameters:
    ///   - defaultsStore: The store used to read and write TextBox settings.
    ///   - catalog: The catalog that provides the TextBox-related setting keys.
    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _showOnNewTerminals = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.showTextBoxOnNewTerminals))
        _focusOnNewTerminals = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.focusTextBoxOnNewTerminals))
        _maxLines = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.textBoxMaxLines))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.textBox", defaultValue: "TextBox (Beta)"), section: .textBox)
            SettingsCard {
                TextBoxBetaWarningNote(
                    String(localized: "settings.textBox.betaWarning", defaultValue: "TextBox is a beta feature. Its defaults and behavior may change while it is being tested.")
                )
                SettingsCardDivider()
                showOnNewTerminalsRow
                SettingsCardDivider()
                focusOnNewTerminalsRow
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
            maxLines,
        ]
        models.forEach { $0.startObserving() }
    }

    @ViewBuilder
    private var showOnNewTerminalsRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.showTextBoxOnNewTerminals"),
            String(localized: "settings.textBox.showOnNewTerminals", defaultValue: "Show TextBox on New Terminals"),
            subtitle: showOnNewTerminals.current
                ? String(localized: "settings.textBox.showOnNewTerminals.subtitleOn", defaultValue: "New terminal tabs, splits, and workspaces open with the TextBox visible.")
                : String(localized: "settings.textBox.showOnNewTerminals.subtitleOff", defaultValue: "New terminals start with the TextBox hidden until you open it.")
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
            subtitle: focusOnNewTerminals.current
                ? String(localized: "settings.textBox.focusOnNewTerminals.subtitleOn", defaultValue: "New terminal tabs, splits, and workspaces put keyboard focus in the TextBox.")
                : String(localized: "settings.textBox.focusOnNewTerminals.subtitleOff", defaultValue: "New terminals keep keyboard focus in the terminal surface.")
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

@MainActor
private struct TextBoxBetaWarningNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .cmuxFont(size: 12, weight: .semibold)
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)

            Text(text)
                .cmuxFont(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
