import CmuxSettings
import SwiftUI

/// **Custom Sidebars** section — renderer controls plus a small native
/// onboarding surface for creating, installing, locating, and editing the
/// filesystem-backed sidebars the existing runtime already discovers.
@MainActor
public struct CustomSidebarsSection: View {
    private let hostActions: SettingsHostActions

    @State private var enabled: DefaultsValueModel<Bool>
    @State private var renderer: JSONValueModel<CustomSidebarRendererMode>
    @State private var discoveredSidebars: [String] = []
    @State private var showingCreateSidebar = false
    @State private var newSidebarName = "my-sidebar"
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
        .alert(
            String(localized: "settings.customSidebars.create", defaultValue: "Create Sidebar", bundle: .module),
            isPresented: $showingCreateSidebar
        ) {
            TextField(
                String(localized: "settings.networking.custom.name", defaultValue: "Name"),
                text: $newSidebarName
            )
            Button(String(localized: "common.create", defaultValue: "Create")) {
                applyOnboardingResult(hostActions.createCustomSidebar(named: newSidebarName))
            }
            .disabled(newSidebarName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(
                String(localized: "settings.customSidebars.create.dialogMessage", defaultValue: "Choose a file name. cmux saves the starter in ~/.config/cmux/sidebars/ and opens it in your preferred editor.", bundle: .module)
            )
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
                String(localized: "settings.customSidebars.create", defaultValue: "Create Sidebar", bundle: .module),
                subtitle: String(localized: "settings.customSidebars.create.subtitle", defaultValue: "Start with a small working sidebar and open it in your preferred editor.", bundle: .module)
            ) {
                Button(String(localized: "settings.customSidebars.create.button", defaultValue: "Create…", bundle: .module)) {
                    operationMessage = nil
                    if newSidebarName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        newSidebarName = "my-sidebar"
                    }
                    showingCreateSidebar = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsCustomSidebarsCreateButton")
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .action,
                String(localized: "settings.customSidebars.examples", defaultValue: "Examples", bundle: .module),
                subtitle: String(localized: "settings.customSidebars.examples.subtitle", defaultValue: "Copy a shipped example into your sidebars folder and open it for editing.", bundle: .module)
            ) {
                Menu {
                    ForEach(CustomSidebarOnboardingAssets.examples) { example in
                        Button(example.title) {
                            applyOnboardingResult(hostActions.installCustomSidebarExample(id: example.id))
                        }
                    }
                } label: {
                    Text(
                        String(localized: "settings.customSidebars.examples.button", defaultValue: "Start From Example…", bundle: .module)
                    )
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsCustomSidebarsExamplesMenu")
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .action,
                String(localized: "settings.customSidebars.folder", defaultValue: "Sidebars Folder", bundle: .module),
                subtitle: String(localized: "settings.customSidebars.folder.subtitle", defaultValue: "Open ~/.config/cmux/sidebars/ in Finder.", bundle: .module)
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
                String(localized: "settings.settingsJSON.documentation", defaultValue: "Documentation"),
                subtitle: String(localized: "settings.customSidebars.documentation.subtitle", defaultValue: "View the authoring guide, live data bindings, actions, and validation commands.", bundle: .module)
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
                String(localized: "settings.customSidebars.yourSidebars", defaultValue: "Your Sidebars", bundle: .module),
                subtitle: String(localized: "settings.customSidebars.yourSidebars.subtitle", defaultValue: "Files discovered in ~/.config/cmux/sidebars/.", bundle: .module)
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
        case .invalidName:
            operationMessage = String(localized: "settings.customSidebars.error.invalidName", defaultValue: "Use a simple file name without slashes.", bundle: .module)
        case .alreadyExists:
            operationMessage = String(localized: "settings.customSidebars.error.alreadyExists", defaultValue: "A sidebar with that name already exists.", bundle: .module)
        case .templateUnavailable:
            operationMessage = String(localized: "settings.customSidebars.error.templateUnavailable", defaultValue: "The bundled sidebar template failed to load or validate.", bundle: .module)
        case .writeFailed:
            operationMessage = String(localized: "settings.customSidebars.error.writeFailed", defaultValue: "cmux failed to write the sidebar file.", bundle: .module)
        }
    }
}
