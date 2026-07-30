import CmuxFoundation
import CmuxSettings
import SwiftUI

@MainActor
struct DynamicNotchAppearanceEditor: View {
    let model: DefaultsValueModel<DynamicNotchAppearance>

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        String(
                            localized: "settings.notifications.dynamicNotch.appearance.title",
                            defaultValue: "Dynamic Notch Appearance"
                        )
                    )
                    .cmuxFont(size: 17, weight: .semibold)

                    Text(
                        String(
                            localized: "settings.notifications.dynamicNotch.editor.subtitle",
                            defaultValue: "These global values update open trays. CLI and JSON notification overrides can replace any token."
                        )
                    )
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button(
                    String(
                        localized: "settings.notifications.dynamicNotch.editor.resetAll",
                        defaultValue: "Reset All"
                    )
                ) {
                    model.reset()
                }
                .disabled(model.current.isDefault)
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(DynamicNotchAppearanceGroup.allCases, id: \.rawValue) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.localizedTitle)
                                .cmuxFont(size: 13, weight: .semibold)
                                .foregroundStyle(.secondary)

                            SettingsCard {
                                let tokens = DynamicNotchAppearanceToken.allCases.filter {
                                    $0.group == group
                                }
                                ForEach(Array(tokens.enumerated()), id: \.element.rawValue) {
                                    index,
                                    token in
                                    DynamicNotchAppearanceTokenRow(
                                        token: token,
                                        appearance: model.current,
                                        reconcileRevision: model.revision
                                    ) { value in
                                        model.set(
                                            model.current.replacing(value, for: token)
                                        )
                                    } reset: {
                                        model.set(model.current.resetting(token))
                                    }

                                    if index < tokens.count - 1 {
                                        SettingsCardDivider()
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button(
                        String(
                            localized: "common.done",
                            defaultValue: "Done"
                    )
                ) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 720, minHeight: 640)
        .accessibilityIdentifier("DynamicNotchAppearanceEditor")
    }
}

@MainActor
private struct DynamicNotchAppearanceTokenRow: View {
    let token: DynamicNotchAppearanceToken
    let appearance: DynamicNotchAppearance
    let reconcileRevision: Int
    let setValue: (DynamicNotchAppearanceValue) -> Void
    let reset: () -> Void

    var body: some View {
        SettingsCardRow(
            configurationReview: .json(
                "notifications.dynamicNotch.\(token.rawValue)"
            ),
            token.rawValue,
            subtitle: token.localizedSummary
        ) {
            HStack(spacing: 8) {
                if appearance[token] != token.defaultValue {
                    Button(
                        String(
                            localized: "settings.app.globalFontMagnification.reset",
                            defaultValue: "Reset"
                        )
                    ) {
                        reset()
                    }
                    .controlSize(.small)
                }

                valueControl
                    .frame(width: 250, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var valueControl: some View {
        switch token.valueKind {
        case .number(let minimum, let maximum, let step):
            HStack(spacing: 8) {
                Slider(
                    value: numberBinding,
                    in: minimum...maximum,
                    step: step
                )
                TextField("", value: numberBinding, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
            }
        case .integer(let minimum, let maximum):
            Stepper(
                value: integerBinding,
                in: minimum...maximum
            ) {
                Text(integerBinding.wrappedValue, format: .number)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .boolean:
            Toggle("", isOn: booleanBinding)
                .labelsHidden()
        case .color:
            colorControl
        }
    }

    private var numberBinding: Binding<Double> {
        Binding(
            get: {
                guard case .number(let value) = appearance[token] else { return 0 }
                return value
            },
            set: { setValue(.number($0)) }
        )
    }

    private var integerBinding: Binding<Int> {
        Binding(
            get: {
                guard case .integer(let value) = appearance[token] else { return 0 }
                return value
            },
            set: { setValue(.integer($0)) }
        )
    }

    private var booleanBinding: Binding<Bool> {
        Binding(
            get: {
                guard case .boolean(let value) = appearance[token] else {
                    return false
                }
                return value
            },
            set: { setValue(.boolean($0)) }
        )
    }

    @ViewBuilder
    private var colorControl: some View {
        let colorHex = currentColorHex
        HStack(spacing: 8) {
            HexColorPicker(
                storedHex: colorHex ?? "#007AFF",
                fallback: .accentColor,
                reconcileRevision: reconcileRevision
            ) { hex in
                guard let value = DynamicNotchAppearanceColor(rawValue: hex) else {
                    return
                }
                setValue(.color(value))
            }

            Text(
                colorHex
                    ?? String(
                        localized: "appearance.system",
                        defaultValue: "System"
                    )
            )
            .cmuxFont(size: 12, weight: .medium, design: .monospaced)
            .foregroundStyle(.secondary)
            .frame(width: 76, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var currentColorHex: String? {
        guard case .color(let value) = appearance[token] else {
            return nil
        }
        switch value {
        case .system:
            return nil
        case .hex(let hex):
            return hex
        }
    }
}

private extension DynamicNotchAppearanceGroup {
    var localizedTitle: String {
        switch self {
        case .layout:
            String(
                localized: "settings.notifications.dynamicNotch.group.layout",
                defaultValue: "Layout"
            )
        case .spacing:
            String(
                localized: "settings.notifications.dynamicNotch.group.spacing",
                defaultValue: "Spacing"
            )
        case .colors:
            String(
                localized: "settings.notifications.dynamicNotch.group.colors",
                defaultValue: "Colors"
            )
        case .behavior:
            String(
                localized: "settings.notifications.dynamicNotch.group.behavior",
                defaultValue: "Behavior"
            )
        }
    }
}

private extension DynamicNotchAppearanceToken {
    var localizedSummary: String {
        switch group {
        case .layout:
            String(
                localized: "settings.notifications.dynamicNotch.token.points",
                defaultValue: "Points"
            )
        case .spacing:
            String(
                localized: "settings.notifications.dynamicNotch.token.points",
                defaultValue: "Points"
            )
        case .colors:
            String(
                localized: "settings.notifications.dynamicNotch.token.color",
                defaultValue: "System color or #RRGGBB"
            )
        case .behavior:
            switch valueKind {
            case .number:
                String(
                    localized: "settings.notifications.dynamicNotch.token.number",
                    defaultValue: "Validated numeric value"
                )
            case .integer:
                String(
                    localized: "settings.notifications.dynamicNotch.token.integer",
                    defaultValue: "Line count"
                )
            case .boolean:
                String(
                    localized: "settings.notifications.dynamicNotch.token.boolean",
                    defaultValue: "Enabled or disabled"
                )
            case .color:
                String(
                    localized: "settings.notifications.dynamicNotch.token.color",
                    defaultValue: "System color or #RRGGBB"
                )
            }
        }
    }
}
