import CmuxSettings
import SwiftUI

/// **Custom Sidebars** section — renderer controls plus a small native
/// onboarding surface for creating, installing, locating, and editing the
/// filesystem-backed sidebars the existing runtime already discovers.
@MainActor
public struct CustomSidebarsSection: View {
    private let hostActions: SettingsHostActions
    private let onboardingAssets = CustomSidebarOnboardingAssets()

    @State private var enabled: DefaultsValueModel<Bool>
    @State private var renderer: JSONValueModel<CustomSidebarRendererMode>
    @State private var discoveredSidebars: [String] = []
    @State private var operationMessage: String?

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        hostActions: SettingsHostActions
    ) {
        self.hostActions = hostActions
        _enabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.customSidebars))
        _renderer = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.customSidebars.renderer,
            errorLog: errorLog
        ))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(
                String(localized: "settings.section.customSidebars", defaultValue: "Custom Sidebars"),
                section: .customSidebars
            )
            SettingsCard {
                enabledRow
                SettingsCardDivider()
                rendererRow
                SettingsCardDivider()
                SettingsCardNote(
                    String(
                        localized: "settings.customSidebars.note",
                        defaultValue: "Custom sidebars are SwiftUI-style files in ~/.config/cmux/sidebars. Pick one from the sidebar toggle button's right-click menu; edits hot-reload on save. Use the in-app renderer only for sidebars you trust."
                    )
                )
            }

            onboardingCard
            discoveredSidebarsCard
        }
        .task {
            startObservingSettings()
            refreshDiscoveredSidebars()
        }
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

    @ViewBuilder
    private var onboardingCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .action,
                String(localized: "commandPalette.kind.customSidebar", defaultValue: "Custom Sidebar")
            ) {
                Button(String(localized: "common.create", defaultValue: "Create")) {
                    applyOnboardingResult(hostActions.createCustomSidebar())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsCustomSidebarsCreateButton")
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .action,
                String(localized: "menu.help.gettingStarted", defaultValue: "Getting Started")
            ) {
                Menu {
                    ForEach(onboardingAssets.examples) { example in
                        Button {
                            applyOnboardingResult(hostActions.installCustomSidebarExample(id: example.id))
                        } label: {
                            Text(verbatim: example.title)
                        }
                    }
                } label: {
                    Text(String(localized: "agentSession.web.start", defaultValue: "Start"))
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsCustomSidebarsExamplesMenu")
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .action,
                String(localized: "sessionIndex.group.directory", defaultValue: "Folder")
            ) {
                Button(String(localized: "shortcut.openFolder.label", defaultValue: "Open Folder")) {
                    hostActions.openCustomSidebarsFolder()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsCustomSidebarsOpenFolderButton")
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .action,
                String(localized: "settings.settingsJSON.documentation", defaultValue: "Documentation")
            ) {
                Link(
                    String(localized: "settings.settingsJSON.docsButton", defaultValue: "Open Docs"),
                    destination: URL(string: "https://cmux.com/docs/custom-sidebars")!
                )
                .cmuxFont(.caption)
                .accessibilityIdentifier("SettingsCustomSidebarsDocsLink")
            }

            if let operationMessage {
                SettingsCardDivider()
                SettingsCardNote(operationMessage)
            }
        }
    }

    @ViewBuilder
    private var discoveredSidebarsCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .action,
                String(localized: "settings.section.customSidebars", defaultValue: "Custom Sidebars")
            ) {
                Text("\(discoveredSidebars.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ForEach(discoveredSidebars, id: \.self) { name in
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .action,
                    name
                ) {
                    Button(String(localized: "settings.common.edit", defaultValue: "Edit")) {
                        hostActions.openCustomSidebarInExternalEditor(named: name)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsCustomSidebarEdit-\(name)")
                }
            }
        }
    }

    private func refreshDiscoveredSidebars() {
        discoveredSidebars = hostActions.customSidebarNames()
    }

    private func applyOnboardingResult(_ result: CustomSidebarOnboardingResult) {
        switch result {
        case .created:
            operationMessage = nil
            enabled.set(true)
            refreshDiscoveredSidebars()
        case .templateUnavailable, .writeFailed:
            operationMessage = String(localized: "settings.networking.check.failed", defaultValue: "Failed")
        }
    }
}
