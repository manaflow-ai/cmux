import CmuxSettings
import SwiftUI

/// **Automation** section.
@MainActor
public struct AutomationSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog

    @State private var socketPasswordModel: JSONValueModel<String>?

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog
    ) {
        self.defaultsStore = defaultsStore
        self.jsonStore = jsonStore
        self.catalog = catalog
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionHeader("Socket Control")
            SettingsCard {
                let socketModeModel = DefaultsValueModel(store: defaultsStore, key: catalog.automation.socketControlMode)
                SettingsCardRow(
                    configurationReview: .json("automation.socketControlMode"),
                    "Socket Control Mode",
                    controlWidth: 240
                ) {
                    Picker("", selection: Binding(get: { socketModeModel.current }, set: { socketModeModel.set($0) })) {
                        Text("Off").tag(SocketControlMode.off)
                        Text("Only the bundled cmux CLI").tag(SocketControlMode.cmuxOnly)
                        Text("Automation tools").tag(SocketControlMode.automation)
                        Text("Password required").tag(SocketControlMode.password)
                        Text("Allow all local clients").tag(SocketControlMode.allowAll)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .json("automation.socketPassword"),
                    "Socket Password",
                    subtitle: "Set when 'Password required' is selected.",
                    controlWidth: 240
                ) {
                    if let model = socketPasswordModel {
                        SecureField("", text: Binding(get: { model.current }, set: { model.set($0) }))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            SettingsSectionHeader("CMUX Port Range")
            SettingsCard {
                intStepperRow("Port Base", subtitle: nil,
                    json: "automation.portBase",
                    key: catalog.automation.portBase,
                    range: 1_024...65_000)
                SettingsCardDivider()
                intStepperRow("Port Range Size", subtitle: nil,
                    json: "automation.portRange",
                    key: catalog.automation.portRange,
                    range: 1...500)
            }
        }
        .task {
            if socketPasswordModel == nil {
                socketPasswordModel = JSONValueModel(store: jsonStore, key: catalog.automation.socketPassword)
            }
        }
    }

    @ViewBuilder
    private func intStepperRow(_ title: String, subtitle: String?, json: String, key: DefaultsKey<Int>, range: ClosedRange<Int>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, subtitle: subtitle, controlWidth: 140) {
            Stepper(value: Binding(get: { model.current }, set: { model.set($0) }), in: range) {
                Text("\(model.current)").monospacedDigit()
            }
            .controlSize(.small)
        }
    }
}
