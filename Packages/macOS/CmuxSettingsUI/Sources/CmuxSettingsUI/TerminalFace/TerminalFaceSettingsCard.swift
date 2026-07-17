import CmuxSettings
import SwiftUI

@MainActor
struct TerminalFaceSettingsCard: View {
    @State private var model: JSONValueModel<TerminalFaceConfiguration>
    @State private var draft: TerminalFaceConfiguration
    @State private var expanded = false

    init(store: JSONConfigStore, key: JSONKey<TerminalFaceConfiguration>, errorLog: SettingsErrorLog) {
        let model = JSONValueModel(store: store, key: key, errorLog: errorLog)
        _model = State(initialValue: model)
        _draft = State(initialValue: key.defaultValue)
    }

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("terminal.face"),
                String(localized: "settings.terminal.face.title", defaultValue: "Terminal Face"),
                subtitle: String(
                    localized: "settings.terminal.face.subtitle",
                    defaultValue: "Draws a customizable face behind terminal text and reacts to agent activity."
                )
            ) {
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { draft.enabled },
                        set: { draft.enabled = $0; save() }
                    ))
                    .labelsHidden()
                    Button(expanded
                        ? String(localized: "settings.terminal.face.hideCustomization", defaultValue: "Hide")
                        : String(localized: "settings.terminal.face.customize", defaultValue: "Customize…")) {
                        expanded.toggle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if expanded {
                SettingsCardDivider()
                TerminalFaceConfigurationEditor(configuration: $draft)
                    .padding(14)
                HStack {
                    Button(String(localized: "settings.terminal.face.reset", defaultValue: "Reset")) {
                        draft = .default
                    }
                    Spacer()
                    Button(String(localized: "settings.terminal.face.apply", defaultValue: "Apply")) {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .task {
            model.startObserving()
            draft = model.current
        }
        .onChange(of: model.current) { _, value in
            if value != draft { draft = value }
        }
    }

    private func save() {
        var sanitized = draft
        sanitized.sanitize()
        model.set(sanitized)
    }
}
