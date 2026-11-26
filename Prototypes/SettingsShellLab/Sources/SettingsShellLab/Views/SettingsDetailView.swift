import SwiftUI

struct SettingsDetailView: View {
    let section: SettingsSection

    @State private var isEnabled = true
    @State private var selectedMode = Mode.system
    @State private var numericValue = 12.0

    var body: some View {
        Form {
            Section {
                LabeledContent(
                    String(localized: "detail.section", defaultValue: "Section"),
                    value: section.title
                )

                Toggle(
                    String(localized: "detail.toggle", defaultValue: "Enable"),
                    isOn: $isEnabled
                )

                Picker(String(localized: "detail.mode", defaultValue: "Mode"), selection: $selectedMode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Slider(
                    value: $numericValue,
                    in: 0...24
                ) {
                    Text(String(localized: "detail.slider", defaultValue: "Amount"))
                }
            } header: {
                Text(section.title)
            }

            Section {
                Button(String(localized: "detail.primaryAction", defaultValue: "Open Related File")) {
                }
                .disabled(true)

                Button(String(localized: "detail.secondaryAction", defaultValue: "Restore Defaults")) {
                }
                .disabled(true)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private enum Mode: String, CaseIterable, Identifiable {
    case system
    case compact
    case expanded

    var id: Self { self }

    var title: String {
        switch self {
        case .system:
            return String(localized: "mode.system", defaultValue: "System")
        case .compact:
            return String(localized: "mode.compact", defaultValue: "Compact")
        case .expanded:
            return String(localized: "mode.expanded", defaultValue: "Expanded")
        }
    }
}
