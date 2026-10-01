import AppKit
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
    @State private var operationMessage: String?
    @State private var galleryPresented = false

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
        .sheet(isPresented: $galleryPresented) {
            CustomSidebarTemplateGallery(hostActions: hostActions) {
                galleryPresented = false
            }
        }
        .task {
            startObservingSettings()
            for await names in await hostActions.customSidebarNamesUpdates() {
                guard !Task.isCancelled else { break }
                discoveredSidebars = names
            }
        }
        .onAppear {
            if CustomSidebarTemplateGalleryRequest.consume() {
                galleryPresented = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .customSidebarTemplateGalleryRequested)) { _ in
            _ = CustomSidebarTemplateGalleryRequest.consume()
            galleryPresented = true
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
            subtitle: String(localized: "settings.customSidebars.enabled.subtitle", defaultValue: "Adds sidebars from ~/.config/cmux/sidebars to the sidebar picker.")
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
            subtitle: String(localized: "settings.customSidebars.renderer.subtitle", defaultValue: "Isolated process protects cmux from a faulty sidebar but accepts clicks only. In-app also accepts hover, focus, and typing.")
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
                .disabled(!enabled.current)
                .accessibilityIdentifier("SettingsCustomSidebarsCreateButton")
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .action,
                searchAnchorID: "setting:customSidebars:templates",
                String(localized: "settings.customSidebars.newFromTemplate", defaultValue: "New from Template…", bundle: .module)
            ) {
                Button {
                    galleryPresented = true
                } label: {
                    Label(
                        String(localized: "settings.customSidebars.browseTemplates", defaultValue: "Browse Templates…", bundle: .module),
                        systemImage: "square.grid.2x2"
                    )
                }
                .controlSize(.small)
                .disabled(!enabled.current)
                .accessibilityIdentifier("SettingsCustomSidebarsTemplatesGalleryButton")
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

            if discoveredSidebars.isEmpty {
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .action,
                    String(localized: "settings.customSidebars.empty.title", defaultValue: "Start with a template", bundle: .module)
                ) {
                    Button(String(localized: "settings.customSidebars.browseTemplates", defaultValue: "Browse Templates…", bundle: .module)) {
                        galleryPresented = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!enabled.current)
                }
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
        case .templateUnavailable:
            operationMessage = String(
                localized: "settings.customSidebars.templateUnavailable",
                defaultValue: "Could not load the sidebar template. Reinstall cmux and try again."
            )
        case .writeFailed:
            operationMessage = String(
                localized: "settings.customSidebars.writeFailed",
                defaultValue: "Could not create the sidebar. Check folder permissions and free disk space, then try again."
            )
        }
    }
}

@MainActor
private struct CustomSidebarTemplateGallery: View {
    let hostActions: SettingsHostActions
    let onClose: () -> Void
    private let assets = CustomSidebarOnboardingAssets()
    @State private var previewingID: String?
    @State private var installedName: String?
    @State private var operationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "settings.customSidebars.gallery.title", defaultValue: "Sidebar Templates", bundle: .module))
                        .font(.title2.weight(.semibold))
                    Text(String(localized: "settings.customSidebars.gallery.subtitle", defaultValue: "Try a curated sidebar before you install it.", bundle: .module))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "common.close", defaultValue: "Close")) {
                    hostActions.revertCustomSidebarPreview()
                    onClose()
                }
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(assets.templates) { template in
                        templateCard(template)
                    }
                }
            }

            if previewingID != nil {
                HStack {
                    Label(String(localized: "settings.customSidebars.gallery.previewing", defaultValue: "Previewing in your sidebar", bundle: .module), systemImage: "eye")
                    Spacer()
                    Button(String(localized: "settings.customSidebars.gallery.revert", defaultValue: "Revert", bundle: .module)) {
                        hostActions.revertCustomSidebarPreview()
                        previewingID = nil
                    }
                    .accessibilityIdentifier("SettingsCustomSidebarTemplateRevert")
                    .keyboardShortcut(.escape, modifiers: [])
                    Button(String(localized: "settings.customSidebars.gallery.keep", defaultValue: "Keep", bundle: .module)) {
                        let result = hostActions.keepCustomSidebarPreview()
                        if case .created = result {
                            previewingID = nil
                            onClose()
                            operationMessage = nil
                        } else {
                            operationMessage = operationMessage(for: result)
                        }
                    }
                    .accessibilityIdentifier("SettingsCustomSidebarTemplateKeep")
                    .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }

            if let installedName {
                HStack {
                    Text(String(format: String(localized: "settings.customSidebars.gallery.installed", defaultValue: "Installed %@", bundle: .module), installedName))
                    Spacer()
                    Button(String(localized: "settings.common.edit", defaultValue: "Edit")) {
                        hostActions.openCustomSidebarInExternalEditor(named: installedName)
                    }
                }
            }

            if let operationMessage {
                Text(operationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 500)
        .onDisappear {
            if previewingID != nil {
                hostActions.revertCustomSidebarPreview()
            }
        }
    }

    @ViewBuilder
    private func templateCard(_ template: CustomSidebarTemplateDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.12))
                .overlay {
                    let theme = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? "light" : "dark"
                    if let url = assets.previewImageURL(id: template.id, theme: theme), let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .clipped()
                    } else {
                        Image(systemName: template.kind == .right ? "sidebar.right" : "sidebar.left")
                            .font(.title2)
                    }
                }
                .frame(height: 105)
            Text(Bundle.module.localizedString(forKey: template.displayNameKey, value: template.displayName, table: nil))
                .font(.headline)
            Text(Bundle.module.localizedString(forKey: template.descriptionKey, value: template.description, table: nil))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(placementLabel(for: template))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack {
                Button(String(localized: "settings.customSidebars.gallery.try", defaultValue: "Try", bundle: .module)) {
                    let result = hostActions.previewCustomSidebarTemplate(id: template.id)
                    if case .created = result {
                        previewingID = template.id
                        operationMessage = nil
                    } else {
                        operationMessage = operationMessage(for: result)
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("SettingsCustomSidebarTemplateTry-\(template.id)")
                Button(String(localized: "settings.customSidebars.gallery.use", defaultValue: "Use", bundle: .module)) {
                    let result = hostActions.useCustomSidebarTemplate(id: template.id)
                    if case let .created(name) = result {
                        installedName = name
                        previewingID = nil
                        operationMessage = nil
                    } else {
                        operationMessage = operationMessage(for: result)
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("SettingsCustomSidebarTemplateUse-\(template.id)")
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func operationMessage(for result: CustomSidebarOnboardingResult) -> String {
        switch result {
        case .templateUnavailable:
            return String(localized: "settings.customSidebars.templateUnavailable", defaultValue: "Could not load the sidebar template. Reinstall cmux and try again.", bundle: .module)
        case .writeFailed:
            return String(localized: "settings.customSidebars.writeFailed", defaultValue: "Could not create the sidebar. Check folder permissions and free disk space, then try again.", bundle: .module)
        case .created:
            return ""
        }
    }

    private func placementLabel(for template: CustomSidebarTemplateDescriptor) -> String {
        if template.kind == .right {
            return String(localized: "settings.customSidebars.gallery.rightPanel", defaultValue: "Right panel", bundle: .module)
        }
        return String(localized: "settings.customSidebars.gallery.leftSidebar", defaultValue: "Left sidebar", bundle: .module)
    }
}
