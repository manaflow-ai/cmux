import CmuxSettings
import SwiftUI

/// **Custom Sidebars** section — the user/agent-authored sidebar
/// surface: the enable toggle (shared with the Beta Features gate) and
/// the renderer picker choosing between the crash-isolated helper
/// process and native in-app rendering.
@MainActor
public struct CustomSidebarsSection: View {
    @State private var enabled: DefaultsValueModel<Bool>
    @State private var renderer: JSONValueModel<CustomSidebarRendererMode>

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog
    ) {
        _enabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.customSidebars))
        _renderer = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.customSidebars.renderer,
            errorLog: errorLog
        ))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.customSidebars", defaultValue: "Custom Sidebars"), section: .customSidebars)
            SettingsCard {
                enabledRow
                SettingsCardDivider()
                rendererRow
                SettingsCardDivider()
                SettingsCardNote(
                    String(localized: "settings.customSidebars.note", defaultValue: "Custom sidebars are SwiftUI-style files in ~/.config/cmux/sidebars. Pick one from the sidebar toggle button's right-click menu; edits hot-reload on save. Use the in-app renderer only for sidebars you trust.")
                )
            }
        }
        .task { startObservingSettings() }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            enabled,
            renderer,
        ]
        models.forEach { $0.startObserving() }
    }

    @ViewBuilder
    private var enabledRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:customSidebars:enabled",
            String(localized: "settings.customSidebars.enabled", defaultValue: "Show Custom Sidebars"),
            subtitle: enabled.current
                ? String(localized: "settings.customSidebars.enabled.subtitleOn", defaultValue: "Lists your sidebars from ~/.config/cmux/sidebars in the sidebar picker.")
                : String(localized: "settings.customSidebars.enabled.subtitleOff", defaultValue: "Hides custom sidebars from the sidebar picker until you enable them here.")
        ) {
            Toggle("", isOn: Binding(get: { enabled.current }, set: { enabled.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsCustomSidebarsEnabledToggle")
        }
    }

    @ViewBuilder
    private var rendererRow: some View {
        SettingsCardRow(
            configurationReview: .json("customSidebars.renderer"),
            String(localized: "settings.customSidebars.renderer", defaultValue: "Renderer"),
            subtitle: renderer.current.rendererDescription
        ) {
            Picker("", selection: Binding(get: { renderer.current }, set: { renderer.set($0) })) {
                ForEach(CustomSidebarRendererMode.uiCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!enabled.current)
            .accessibilityIdentifier("SettingsCustomSidebarsRendererPicker")
        }
    }
}
