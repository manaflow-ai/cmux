import CmuxSettings
import SwiftUI

/// SwiftUI view for the **App** section of the settings window.
///
/// Mirrors the legacy in-app settings layout: a single scrolling form
/// with subsections for Appearance, Window/Workspace behavior, Command
/// palette, Quit/Close warnings, Editor, File handling, Workspace
/// presentation, Notifications, and Telemetry. Every row is wired to a
/// catalog ``DefaultsKey`` via the matching value-model + row primitive
/// so writes flow through ``UserDefaultsSettingsStore`` and observation
/// flows through its `AsyncStream`.
@MainActor
public struct AppSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
    }

    public var body: some View {
        Form {
            appearanceSection
            workspaceBehaviorSection
            commandPaletteSection
            quitAndCloseSection
            editorSection
            fileHandlingSection
            workspacePresentationSection
            notificationsSection
            telemetrySection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var appearanceSection: some View {
        Section("Appearance") {
            SettingsPickerRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.appearance),
                title: "Appearance",
                label: { mode in
                    switch mode {
                    case .system: return "Follow System"
                    case .light: return "Light"
                    case .dark: return "Dark"
                    }
                }
            )
            SettingsPickerRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.appIcon),
                title: "App Icon",
                label: { mode in
                    switch mode {
                    case .automatic: return "Automatic"
                    case .light: return "Light"
                    case .dark: return "Dark"
                    }
                }
            )
            SettingsPickerRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.language),
                title: "Language",
                label: { lang in displayName(for: lang) }
            )
        }
    }

    @ViewBuilder
    private var workspaceBehaviorSection: some View {
        Section("Workspace Behavior") {
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.workspaceInheritWorkingDirectory),
                title: "Inherit Working Directory",
                subtitle: "New panes in a workspace start in the same working directory as the previous pane."
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.keepWorkspaceOpenWhenClosingLastSurface),
                title: "Keep Workspace Open After Last Pane Closes",
                subtitle: "When the last pane in a workspace closes, keep the workspace itself open."
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.focusPaneOnFirstClick),
                title: "Focus Pane on First Click",
                subtitle: "Clicking an unfocused pane focuses it on the very first click rather than swallowing the click."
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.reorderOnNotification),
                title: "Reorder Workspaces on Notification",
                subtitle: "Bubble a workspace to the top of the sidebar when a pane in it posts a notification."
            )
            SettingsPickerRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.newWorkspacePlacement),
                title: "New Workspace Placement",
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

    @ViewBuilder
    private var commandPaletteSection: some View {
        Section("Command Palette") {
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.renameSelectsExistingName),
                title: "Select Existing Name When Renaming",
                subtitle: "Pre-select the workspace name when the rename palette opens, so typing replaces it immediately."
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.commandPaletteSearchesAllSurfaces),
                title: "Search All Surfaces",
                subtitle: "The command palette includes panes from every workspace, not just the current one."
            )
        }
    }

    @ViewBuilder
    private var quitAndCloseSection: some View {
        Section("Quit and Close") {
            SettingsPickerRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.confirmQuitMode),
                title: "Confirm Quit",
                label: { mode in
                    switch mode {
                    case .always: return "Always"
                    case .dirtyOnly: return "Only If Workspaces Are Active"
                    case .never: return "Never"
                    }
                }
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.warnBeforeQuit),
                title: "Warn Before Quitting (⌘Q)",
                subtitle: "Show a confirmation when ⌘Q is pressed."
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.warnBeforeClosingTab),
                title: "Warn Before Closing Tab",
                subtitle: "Show a confirmation when a tab is closed via shortcut."
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.warnBeforeClosingTabXButton),
                title: "Warn When Closing Tab via X Button",
                subtitle: "Also show the confirmation when the tab's close button is clicked."
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.hideTabCloseButton),
                title: "Hide Tab Close Button",
                subtitle: "Removes the X on each tab so tabs can only be closed via shortcut or menu."
            )
        }
    }

    @ViewBuilder
    private var editorSection: some View {
        Section("Editor") {
            SettingsDefaultsTextFieldRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.preferredEditor),
                title: "Preferred Editor Command",
                placeholder: "code, cursor, zed, nvim …",
                subtitle: "Command run when cmd-clicking a file path. Leave empty to use the system default."
            )
        }
    }

    @ViewBuilder
    private var fileHandlingSection: some View {
        Section("File Handling") {
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.openSupportedFilesInCmux),
                title: "Open Supported Files in cmux",
                subtitle: "PDF, images, audio, video, and other Quick Look-able files open in a cmux preview surface."
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.openMarkdownInCmuxViewer),
                title: "Open Markdown in cmux Viewer",
                subtitle: "Markdown files open in a cmux preview pane instead of the system default editor."
            )
            SettingsPickerRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.fileDropDefaultBehavior),
                title: "Default Drag-and-Drop Behavior",
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

    @ViewBuilder
    private var workspacePresentationSection: some View {
        Section("Workspace Presentation") {
            SettingsPickerRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.presentationMode),
                title: "Workspace Presentation Mode",
                label: { mode in
                    switch mode {
                    case .standard: return "Standard"
                    case .minimal: return "Minimal"
                    }
                }
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.iMessageMode),
                title: "iMessage Mode",
                subtitle: "Hides the dock badge and shows a compact, chat-like workspace presentation."
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.menuBarOnly),
                title: "Menu Bar Only",
                subtitle: "Hide the dock icon. cmux is reachable only from the menu bar."
            )
        }
    }

    @ViewBuilder
    private var notificationsSection: some View {
        NotificationsRows(defaultsStore: defaultsStore, catalog: catalog)
    }

    @ViewBuilder
    private var telemetrySection: some View {
        Section("Telemetry") {
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.app.sendAnonymousTelemetry),
                title: "Send Anonymous Telemetry",
                subtitle: "cmux sends anonymized usage events to help fix bugs and improve the product. No file contents, secrets, or workspace metadata are sent."
            )
        }
    }

    private func displayName(for language: AppLanguage) -> String {
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
