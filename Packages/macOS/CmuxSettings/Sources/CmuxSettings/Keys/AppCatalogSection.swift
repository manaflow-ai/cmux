import Foundation

/// Settings under the dotted-id prefix `app.*` — user-facing app behavior.
public struct AppCatalogSection: SettingCatalogSection {
    public let appearance = DefaultsKey<AppearanceMode>(
        id: "app.appearance",
        defaultValue: .system,
        userDefaultsKey: "appearanceMode"
    )

    public let language = DefaultsKey<AppLanguage>(
        id: "app.language",
        defaultValue: .system,
        userDefaultsKey: "appLanguage"
    )

    public let appIcon = DefaultsKey<AppIconMode>(
        id: "app.appIcon",
        defaultValue: .automatic,
        userDefaultsKey: "appIconMode"
    )

    /// Optional macOS window title template. Empty preserves the default
    /// active-workspace title behavior.
    public let windowTitleTemplate = DefaultsKey<String>(
        id: "app.windowTitleTemplate",
        defaultValue: "",
        userDefaultsKey: "windowTitleTemplate"
    )

    public let menuBarOnly = DefaultsKey<Bool>(
        id: "app.menuBarOnly",
        defaultValue: false,
        userDefaultsKey: "menuBarOnly"
    )

    public let newWorkspacePlacement = DefaultsKey<WorkspacePlacement>(
        id: "app.newWorkspacePlacement",
        defaultValue: .afterCurrent,
        userDefaultsKey: "newWorkspacePlacement"
    )

    public let workspaceInheritWorkingDirectory = DefaultsKey<Bool>(
        id: "app.workspaceInheritWorkingDirectory",
        defaultValue: true,
        userDefaultsKey: "workspaceInheritWorkingDirectory"
    )

    public let presentationMode = DefaultsKey<WorkspacePresentationMode>(
        id: "app.minimalMode",
        defaultValue: .standard,
        userDefaultsKey: "workspacePresentationMode"
    )

    /// Stored under the legacy `closeWorkspaceOnLastSurfaceShortcut` key
    /// whose value carries *close*-on-last-surface semantics (true =
    /// close the workspace), with legacy default `true`. The "Keep
    /// Workspace Open" toggle in the UI therefore binds to the inverse
    /// of this value, matching the legacy SettingsView.
    public let keepWorkspaceOpenWhenClosingLastSurface = DefaultsKey<Bool>(
        id: "app.keepWorkspaceOpenWhenClosingLastSurface",
        defaultValue: true,
        userDefaultsKey: "closeWorkspaceOnLastSurfaceShortcut"
    )

    public let focusPaneOnFirstClick = DefaultsKey<Bool>(
        id: "app.focusPaneOnFirstClick",
        defaultValue: false,
        userDefaultsKey: "paneFirstClickFocus.enabled"
    )

    public let preferredEditor = DefaultsKey<String>(
        id: "app.preferredEditor",
        defaultValue: "",
        userDefaultsKey: "preferredEditorCommand"
    )

    public let openSupportedFilesInCmux = DefaultsKey<Bool>(
        id: "app.openSupportedFilesInCmux",
        defaultValue: true,
        userDefaultsKey: "openSupportedFilesInCmux"
    )

    /// Default `true` matches the runtime cmd-click router (legacy
    /// `CmdClickMarkdownRouteSettings.defaultValue`); the catalog briefly
    /// said `false`, which made the Settings toggle display OFF for users
    /// who never changed it while the route was actually active.
    public let openMarkdownInCmuxViewer = DefaultsKey<Bool>(
        id: "app.openMarkdownInCmuxViewer",
        defaultValue: true,
        userDefaultsKey: "openMarkdownInCmuxViewer"
    )

    public let iMessageMode = DefaultsKey<Bool>(
        id: "app.iMessageMode",
        defaultValue: false,
        userDefaultsKey: "app.iMessageMode"
    )

    public let reorderOnNotification = DefaultsKey<Bool>(
        id: "app.reorderOnNotification",
        defaultValue: true,
        userDefaultsKey: "workspaceAutoReorderOnNotification"
    )

    public let sendAnonymousTelemetry = DefaultsKey<Bool>(
        id: "app.sendAnonymousTelemetry",
        defaultValue: true,
        userDefaultsKey: "sendAnonymousTelemetry"
    )

    public let confirmQuitMode = DefaultsKey<ConfirmQuitMode>(
        id: "app.confirmQuit",
        defaultValue: .always,
        userDefaultsKey: "confirmQuit"
    )

    public let warnBeforeQuit = DefaultsKey<Bool>(
        id: "app.warnBeforeQuit",
        defaultValue: true,
        userDefaultsKey: "warnBeforeQuitShortcut"
    )

    public let warnBeforeClosingTab = DefaultsKey<Bool>(
        id: "app.warnBeforeClosingTab",
        defaultValue: true,
        userDefaultsKey: "warnBeforeClosingTabShortcut"
    )

    public let warnBeforeClosingTabXButton = DefaultsKey<Bool>(
        id: "app.warnBeforeClosingTabXButton",
        defaultValue: false,
        userDefaultsKey: "warnBeforeClosingTabXButton"
    )

    public let hideTabCloseButton = DefaultsKey<Bool>(
        id: "app.hideTabCloseButton",
        defaultValue: false,
        userDefaultsKey: "hideTabCloseButton"
    )

    public let renameSelectsExistingName = DefaultsKey<Bool>(
        id: "app.renameSelectsExistingName",
        defaultValue: true,
        userDefaultsKey: "commandPalette.renameSelectAllOnFocus"
    )

    public let commandPaletteSearchesAllSurfaces = DefaultsKey<Bool>(
        id: "app.commandPaletteSearchesAllSurfaces",
        defaultValue: false,
        userDefaultsKey: "commandPalette.switcherSearchAllSurfaces"
    )

    public let fileDropDefaultBehavior = DefaultsKey<FileDropDefaultBehavior>(
        id: "app.fileDropDefaultBehavior",
        defaultValue: .text,
        userDefaultsKey: "fileDrop.defaultBehavior"
    )

    /// Titlebar controls style. Legacy stores the `Int` raw value of
    /// `TitlebarControlsStyle` (`.classic == 0`) under
    /// `titlebarControlsStyle`; a `String` here would write a value the
    /// app's `integer(forKey:)` readers can't decode.
    public let titlebarControlsStyle = DefaultsKey<Int>(
        id: "app.titlebarControlsStyle",
        defaultValue: 0,
        userDefaultsKey: "titlebarControlsStyle"
    )

    /// Workspace button fade mode. Legacy `WorkspaceButtonFadeSettings`
    /// stores the `String` raw value of its `enabled`/`disabled` enum
    /// (default `disabled`) under `workspaceButtonsFadeMode`.
    public let workspaceButtonFade = DefaultsKey<String>(
        id: "app.workspaceButtonFade",
        defaultValue: "disabled",
        userDefaultsKey: "workspaceButtonsFadeMode"
    )

    /// Workspace titlebar visibility. Legacy `WorkspaceTitlebarSettings`
    /// stores a `Bool` (default `true`) under `workspaceTitlebarVisible`.
    public let workspaceTitlebarVisibility = DefaultsKey<Bool>(
        id: "app.workspaceTitlebarVisibility",
        defaultValue: true,
        userDefaultsKey: "workspaceTitlebarVisible"
    )

    public let systemWideHotkeyEnabled = DefaultsKey<Bool>(
        id: "app.systemWideHotkeyEnabled",
        defaultValue: false,
        userDefaultsKey: "systemWideHotkey.enabled"
    )

    /// Shared, cross-tag default display that DEBUG cmux builds open new
    /// windows on, identified by the display's `localizedName` (e.g.
    /// `"LG HDR 4K"`). Empty means the system default placement.
    ///
    /// JSON-backed (`JSONKey`) on purpose: `cmux.json` lives at a fixed path
    /// shared by every bundle id, so one value is honored by every tagged dev
    /// build and every launch path. `UserDefaults` is per-bundle and would not
    /// be shared. Release builds never read it.
    public let devWindowDisplay = JSONKey<String>(
        id: "app.devWindowDisplay",
        defaultValue: ""
    )

    public init() {}
}
