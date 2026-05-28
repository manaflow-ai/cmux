import CmuxSettings
import SwiftUI

/// **App** section rendered in the settings ScrollView.
///
/// Emits a stacked sequence of ``SettingsSectionHeader`` +
/// ``SettingsCard`` groups mirroring the legacy in-app layout:
/// Appearance, Workspace Behavior, Command Palette, Quit/Close,
/// Editor, File Handling, Workspace Presentation, Notifications,
/// Telemetry, Onboarding, Feedback.
@MainActor
public struct AppSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog
    private let hostActions: SettingsHostActions?

    @State private var initialLanguage: AppLanguage?
    @State private var pendingRestart: Bool = false

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions? = nil
    ) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
        self.hostActions = hostActions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionHeader("App")

            appearanceCard
            workspaceBehaviorCard
            commandPaletteCard
            quitAndCloseCard
            editorCard
            fileHandlingCard
            workspacePresentationCard
            notificationsCard
            telemetryCard
            onboardingCard
            feedbackCard
        }
        .confirmationDialog(
            "Restart cmux to apply the new language?",
            isPresented: $pendingRestart,
            titleVisibility: .visible
        ) {
            if let hostActions {
                Button("Restart Now") { hostActions.restartApp() }
            }
            Button("Later", role: .cancel) {
                initialLanguage = currentLanguage()
            }
        } message: {
            Text("Language changes apply on the next launch.")
        }
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearanceCard: some View {
        SettingsCard {
            row(
                title: "Appearance",
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.appearance),
                json: "app.appearance",
                cases: AppearanceMode.allCases,
                label: { mode in
                    switch mode {
                    case .system: return "Follow System"
                    case .light: return "Light"
                    case .dark: return "Dark"
                    }
                }
            )
            SettingsCardDivider()
            appIconRow
            SettingsCardDivider()
            languageRow
        }
    }

    @ViewBuilder
    private var appIconRow: some View {
        SettingsCardRow(
            configurationReview: .json("app.appIcon"),
            "App Icon"
        ) {
            AppIconGridPicker(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.appIcon)
            )
        }
    }

    @ViewBuilder
    private var languageRow: some View {
        let model = DefaultsValueModel(store: defaultsStore, key: catalog.app.language)
        SettingsCardRow(
            configurationReview: .json("app.language"),
            "Language",
            controlWidth: 200
        ) {
            Picker("", selection: Binding(
                get: { model.current },
                set: { newValue in
                    if let initial = initialLanguage ?? Optional(model.current), newValue != initial {
                        if initialLanguage == nil { initialLanguage = initial }
                        model.set(newValue)
                        if newValue != initial { pendingRestart = true }
                    } else {
                        model.set(newValue)
                    }
                }
            )) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(languageDisplayName(lang)).tag(lang)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func currentLanguage() -> AppLanguage {
        DefaultsValueModel(store: defaultsStore, key: catalog.app.language).current
    }

    // MARK: - Workspace Behavior

    @ViewBuilder
    private var workspaceBehaviorCard: some View {
        SettingsSectionHeader("Workspace")
        SettingsCard {
            toggleRow(
                title: "Inherit Working Directory",
                subtitle: "New panes in a workspace start in the same working directory as the previous pane.",
                json: "app.workspaceInheritWorkingDirectory",
                key: catalog.app.workspaceInheritWorkingDirectory
            )
            SettingsCardDivider()
            toggleRow(
                title: "Keep Workspace Open After Last Pane Closes",
                subtitle: "When the last pane in a workspace closes, keep the workspace itself open.",
                json: "app.keepWorkspaceOpenWhenClosingLastSurface",
                key: catalog.app.keepWorkspaceOpenWhenClosingLastSurface
            )
            SettingsCardDivider()
            toggleRow(
                title: "Focus Pane on First Click",
                subtitle: "Clicking an unfocused pane focuses it on the very first click.",
                json: "app.focusPaneOnFirstClick",
                key: catalog.app.focusPaneOnFirstClick
            )
            SettingsCardDivider()
            toggleRow(
                title: "Reorder Workspaces on Notification",
                subtitle: "Bubble a workspace to the top of the sidebar when a pane in it posts a notification.",
                json: "app.reorderOnNotification",
                key: catalog.app.reorderOnNotification
            )
            SettingsCardDivider()
            row(
                title: "New Workspace Placement",
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.newWorkspacePlacement),
                json: "app.newWorkspacePlacement",
                cases: WorkspacePlacement.allCases,
                label: { placement in
                    switch placement {
                    case .top: return "Top of Sidebar"
                    case .end: return "End of Sidebar"
                    case .afterCurrent: return "Below Current"
                    }
                }
            )
        }
    }

    // MARK: - Command Palette

    @ViewBuilder
    private var commandPaletteCard: some View {
        SettingsSectionHeader("Command Palette")
        SettingsCard {
            toggleRow(
                title: "Select Existing Name When Renaming",
                subtitle: "Pre-select the workspace name when the rename palette opens, so typing replaces it immediately.",
                json: "app.renameSelectsExistingName",
                key: catalog.app.renameSelectsExistingName
            )
            SettingsCardDivider()
            toggleRow(
                title: "Search All Surfaces",
                subtitle: "The command palette includes panes from every workspace, not just the current one.",
                json: "app.commandPaletteSearchesAllSurfaces",
                key: catalog.app.commandPaletteSearchesAllSurfaces
            )
        }
    }

    // MARK: - Quit and Close

    @ViewBuilder
    private var quitAndCloseCard: some View {
        SettingsSectionHeader("Quit and Close")
        SettingsCard {
            row(
                title: "Confirm Quit",
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.confirmQuitMode),
                json: "app.confirmQuit",
                cases: ConfirmQuitMode.allCases,
                label: { mode in
                    switch mode {
                    case .always: return "Always"
                    case .dirtyOnly: return "Only If Workspaces Are Active"
                    case .never: return "Never"
                    }
                }
            )
            SettingsCardDivider()
            toggleRow(
                title: "Warn Before Quitting (⌘Q)",
                subtitle: "Show a confirmation when ⌘Q is pressed.",
                json: "app.warnBeforeQuit",
                key: catalog.app.warnBeforeQuit
            )
            SettingsCardDivider()
            toggleRow(
                title: "Warn Before Closing Tab",
                subtitle: "Show a confirmation when a tab is closed via shortcut.",
                json: "app.warnBeforeClosingTab",
                key: catalog.app.warnBeforeClosingTab
            )
            SettingsCardDivider()
            toggleRow(
                title: "Warn When Closing Tab via X Button",
                subtitle: "Also show the confirmation when the tab's close button is clicked.",
                json: "app.warnBeforeClosingTabXButton",
                key: catalog.app.warnBeforeClosingTabXButton
            )
            SettingsCardDivider()
            toggleRow(
                title: "Hide Tab Close Button",
                subtitle: "Removes the X on each tab so tabs can only be closed via shortcut or menu.",
                json: "app.hideTabCloseButton",
                key: catalog.app.hideTabCloseButton
            )
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editorCard: some View {
        SettingsSectionHeader("Editor")
        SettingsCard {
            textRow(
                title: "Preferred Editor Command",
                subtitle: "Command run when cmd-clicking a file path. Leave empty to use the system default.",
                placeholder: "code, cursor, zed, nvim …",
                json: "app.preferredEditor",
                key: catalog.app.preferredEditor
            )
        }
    }

    // MARK: - File Handling

    @ViewBuilder
    private var fileHandlingCard: some View {
        SettingsSectionHeader("File Handling")
        SettingsCard {
            toggleRow(
                title: "Open Supported Files in cmux",
                subtitle: "PDF, images, audio, video, and other Quick Look-able files open in a cmux preview surface.",
                json: "app.openSupportedFilesInCmux",
                key: catalog.app.openSupportedFilesInCmux
            )
            SettingsCardDivider()
            toggleRow(
                title: "Open Markdown in cmux Viewer",
                subtitle: "Markdown files open in a cmux preview pane instead of the system default editor.",
                json: "app.openMarkdownInCmuxViewer",
                key: catalog.app.openMarkdownInCmuxViewer
            )
            SettingsCardDivider()
            row(
                title: "Default Drag-and-Drop Behavior",
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.fileDropDefaultBehavior),
                json: "app.fileDropDefaultBehavior",
                cases: FileDropDefaultBehavior.allCases,
                label: { behavior in
                    switch behavior {
                    case .path: return "Insert File Path"
                    case .editor: return "Open in Preferred Editor"
                    case .preview: return "Open in cmux Preview"
                    }
                }
            )
        }
    }

    // MARK: - Workspace Presentation

    @ViewBuilder
    private var workspacePresentationCard: some View {
        SettingsSectionHeader("Workspace Presentation")
        SettingsCard {
            row(
                title: "Workspace Presentation Mode",
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.presentationMode),
                json: "app.minimalMode",
                cases: WorkspacePresentationMode.allCases,
                label: { mode in
                    switch mode {
                    case .standard: return "Standard"
                    case .minimal: return "Minimal"
                    }
                }
            )
            SettingsCardDivider()
            toggleRow(
                title: "iMessage Mode",
                subtitle: "Hides the dock badge and shows a compact, chat-like workspace presentation.",
                json: "app.iMessageMode",
                key: catalog.app.iMessageMode
            )
            SettingsCardDivider()
            toggleRow(
                title: "Menu Bar Only",
                subtitle: "Hide the dock icon. cmux is reachable only from the menu bar.",
                json: "app.menuBarOnly",
                key: catalog.app.menuBarOnly
            )
        }
    }

    // MARK: - Notifications

    @ViewBuilder
    private var notificationsCard: some View {
        SettingsSectionHeader("Notifications")
        SettingsCard {
            toggleRow(
                title: "Dock Badge",
                subtitle: "Show the unread notification count on the cmux app icon.",
                json: "notifications.dockBadge",
                key: catalog.notifications.dockBadge
            )
            SettingsCardDivider()
            toggleRow(
                title: "Show Menu Bar Extra",
                subtitle: nil,
                json: "notifications.showInMenuBar",
                key: catalog.notifications.showInMenuBar
            )
            SettingsCardDivider()
            toggleRow(
                title: "Unread Pane Ring",
                subtitle: "Outline panes with unread notifications in the workspace's color.",
                json: "notifications.unreadPaneRing",
                key: catalog.notifications.unreadPaneRing
            )
            SettingsCardDivider()
            toggleRow(
                title: "Pane Flash",
                subtitle: nil,
                json: "notifications.paneFlash",
                key: catalog.notifications.paneFlash
            )
            if let hostActions {
                SettingsCardDivider()
                SettingsCardRow(configurationReview: .action, "Permission") {
                    HStack(spacing: 8) {
                        Button("Request Permission") { hostActions.requestNotificationAuthorization() }
                        Button("System Settings…") { hostActions.openSystemNotificationSettings() }
                        Button("Send Test") { hostActions.sendTestNotification() }
                    }
                    .controlSize(.small)
                }
            }
        }

        SettingsSectionHeader("Notification Sound")
        SettingsCard {
            textRow(
                title: "Sound",
                subtitle: "NSSound name, the literal \"default\", \"none\", or \"custom\" to use the file path below.",
                placeholder: "default | none | Frog | Glass | …",
                json: "notifications.sound",
                key: catalog.notifications.sound
            )
            SettingsCardDivider()
            textRow(
                title: "Custom Sound File",
                subtitle: "Used when Sound is set to \"custom\".",
                placeholder: "/path/to/sound.aiff",
                json: "notifications.customSoundFilePath",
                key: catalog.notifications.customSoundFilePath
            )
            SettingsCardDivider()
            textRow(
                title: "Custom Notification Command",
                subtitle: "Optional shell command run on every notification. Leave empty to skip.",
                placeholder: "afplay /path/to/sound.wav",
                json: "notifications.command",
                key: catalog.notifications.command
            )
        }
    }

    // MARK: - Telemetry

    @ViewBuilder
    private var telemetryCard: some View {
        SettingsSectionHeader("Telemetry")
        SettingsCard {
            toggleRow(
                title: "Send Anonymous Telemetry",
                subtitle: "cmux sends anonymized usage events to help fix bugs and improve the product. No file contents, secrets, or workspace metadata are sent.",
                json: "app.sendAnonymousTelemetry",
                key: catalog.app.sendAnonymousTelemetry
            )
        }
    }

    @ViewBuilder
    private var onboardingCard: some View {
        SettingsSectionHeader("Onboarding")
        SettingsCard {
            toggleRow(
                title: "Welcome Shown",
                subtitle: "Toggle off to surface the welcome flow again on next launch.",
                json: "account.welcomeShown",
                key: catalog.account.welcomeShown
            )
        }
    }

    @ViewBuilder
    private var feedbackCard: some View {
        if let hostActions {
            SettingsSectionHeader("Feedback")
            SettingsCard {
                SettingsCardRow(configurationReview: .action, "Send Feedback") {
                    Button("Send Feedback…") { hostActions.sendFeedback() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func toggleRow(title: String, subtitle: String?, json: String, key: DefaultsKey<Bool>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, subtitle: subtitle) {
            Toggle("", isOn: Binding(get: { model.current }, set: { model.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func textRow(title: String, subtitle: String?, placeholder: String, json: String, key: DefaultsKey<String>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, subtitle: subtitle, controlWidth: 240) {
            TextField(placeholder, text: Binding(get: { model.current }, set: { model.set($0) }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func row<Value: SettingCodable & Hashable & CaseIterable>(
        title: String,
        model: DefaultsValueModel<Value>,
        json: String,
        cases: [Value],
        label: @escaping (Value) -> String
    ) -> some View {
        SettingsCardRow(configurationReview: .json(json), title, controlWidth: 200) {
            Picker("", selection: Binding(get: { model.current }, set: { model.set($0) })) {
                ForEach(cases, id: \.self) { value in
                    Text(label(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func languageDisplayName(_ language: AppLanguage) -> String {
        switch language {
        case .system: return "Follow System"
        case .en: return "English"
        case .ar: return "العربية"
        case .bs: return "Bosanski"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .da: return "Dansk"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .fr: return "Français"
        case .it: return "Italiano"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .nb: return "Norsk Bokmål"
        case .pl: return "Polski"
        case .ptBR: return "Português (Brasil)"
        case .ru: return "Русский"
        case .th: return "ไทย"
        case .tr: return "Türkçe"
        case .vi: return "Tiếng Việt"
        }
    }
}
