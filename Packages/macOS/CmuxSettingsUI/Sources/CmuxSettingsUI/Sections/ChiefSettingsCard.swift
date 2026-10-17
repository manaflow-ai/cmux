import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Settings card for Chief, the Home agent (`chief.*`).
///
/// One card, laid out like a provider block: an on/off row, then the harness
/// picker and the model and effort fields. The harness rows stay visible while
/// Chief is off so search results always land on a row.
@MainActor
struct ChiefSettingsCard: View {
    @State private var enabledModel: DefaultsValueModel<Bool>
    @State private var harnessModel: DefaultsValueModel<String>
    @State private var modelModel: DefaultsValueModel<String>
    @State private var effortModel: DefaultsValueModel<String>
    @State private var dangerousPermissionsModel: DefaultsValueModel<Bool>
    @State private var showingDangerousPermissionsConfirmation = false
    private let controlWidth: CGFloat

    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog, controlWidth: CGFloat) {
        _enabledModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.chief.enabled))
        _harnessModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.chief.harness))
        _modelModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.chief.model))
        _effortModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.chief.effort))
        _dangerousPermissionsModel = State(initialValue: DefaultsValueModel(store: defaultsStore,
                                                                              key: catalog.chief.dangerouslySkipPermissions))
        self.controlWidth = controlWidth
    }

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("chief.enabled"),
                String(localized: "settings.automation.chief", defaultValue: "Chief", bundle: .module),
                subtitle: enabledModel.current
                    ? String(localized: "settings.automation.chief.subtitleOn", defaultValue: "Home and Open Chief are shown.", bundle: .module)
                    : String(localized: "settings.automation.chief.subtitleOff", defaultValue: "Home and Chief entry points are hidden.", bundle: .module)
            ) {
                Toggle("", isOn: Binding(get: { enabledModel.current }, set: { enabledModel.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsChiefEnabledToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("chief.dangerouslySkipPermissions"),
                String(localized: "settings.automation.chief.dangerousPermissions", defaultValue: "Skip permission prompts", bundle: .module),
                subtitle: String(localized: "settings.automation.chief.dangerousPermissions.subtitle",
                                  defaultValue: "Let Chief's agent run commands without approval cards. Off by default.", bundle: .module)
            ) {
                Toggle("", isOn: Binding(
                    get: { dangerousPermissionsModel.current },
                    set: { enabled in
                        guard enabled != dangerousPermissionsModel.current else { return }
                        if enabled {
                            showingDangerousPermissionsConfirmation = true
                        } else {
                            dangerousPermissionsModel.set(false)
                        }
                    }
                ))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsChiefDangerousPermissionsToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("chief.harness"),
                String(localized: "settings.automation.chief.harness", defaultValue: "Chief Harness", bundle: .module),
                subtitle: String(localized: "settings.automation.chief.harness.subtitle", defaultValue: "The agent Chief runs on.", bundle: .module),
                controlWidth: controlWidth
            ) {
                Picker("", selection: Binding(get: { harnessSelection }, set: { harnessModel.set($0.rawValue) })) {
                    ForEach(ChiefHarnessSetting.allCases, id: \.self) { harness in
                        Text(Self.displayName(for: harness)).tag(harness)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("SettingsChiefHarnessPicker")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("chief.model"),
                String(localized: "settings.automation.chief.model", defaultValue: "Chief Model", bundle: .module),
                subtitle: String(localized: "settings.automation.chief.model.subtitle", defaultValue: "Leave empty to use the harness default.", bundle: .module)
            ) {
                TextField(
                    String(localized: "settings.automation.chief.default.placeholder", defaultValue: "Harness default", bundle: .module),
                    text: Binding(get: { modelModel.current }, set: { modelModel.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .accessibilityIdentifier("SettingsChiefModelField")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("chief.effort"),
                String(localized: "settings.automation.chief.effort", defaultValue: "Chief Effort", bundle: .module),
                subtitle: String(localized: "settings.automation.chief.effort.subtitle", defaultValue: "Reasoning effort, such as low, medium, or high. Leave empty to use the harness default.", bundle: .module)
            ) {
                TextField(
                    String(localized: "settings.automation.chief.default.placeholder", defaultValue: "Harness default", bundle: .module),
                    text: Binding(get: { effortModel.current }, set: { effortModel.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .accessibilityIdentifier("SettingsChiefEffortField")
            }
        }
        .confirmationDialog(
            String(localized: "settings.automation.chief.dangerousPermissions.confirm.title",
                   defaultValue: "Skip permission prompts?", bundle: .module),
            isPresented: $showingDangerousPermissionsConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "settings.automation.chief.dangerousPermissions.confirm.enable",
                       defaultValue: "Turn On", bundle: .module),
                role: .destructive
            ) {
                dangerousPermissionsModel.set(true)
            }
            Button(
                String(localized: "settings.automation.chief.dangerousPermissions.confirm.cancel",
                       defaultValue: "Cancel", bundle: .module),
                role: .cancel
            ) {}
        } message: {
            Text(String(localized: "settings.automation.chief.dangerousPermissions.confirm.message",
                        defaultValue: "The selected agent can run commands and make changes without approval cards. This is a dangerous setting.",
                        bundle: .module))
        }
        .task {
            startSettingsObservation([enabledModel, harnessModel, modelModel, effortModel, dangerousPermissionsModel])
        }
    }

    private var harnessSelection: ChiefHarnessSetting {
        ChiefHarnessSetting(rawValue: harnessModel.current) ?? .defaultHarness
    }

    private static func displayName(for harness: ChiefHarnessSetting) -> String {
        switch harness {
        case .claude:
            return String(localized: "settings.automation.chief.harness.claude", defaultValue: "Claude Code", bundle: .module)
        case .codex:
            return String(localized: "settings.automation.chief.harness.codex", defaultValue: "Codex", bundle: .module)
        }
    }
}
