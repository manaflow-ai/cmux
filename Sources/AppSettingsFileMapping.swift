import CmuxSettings

enum AppSettingsFileMapping {
    private static let app = AppCatalogSection()

    static let booleanSettings: [SettingsFileBooleanMapping] = [
        .init(
            jsonKey: "workspaceInheritWorkingDirectory",
            defaultsKey: app.workspaceInheritWorkingDirectory.userDefaultsKey,
            invalidPath: "app.workspaceInheritWorkingDirectory"
        ),
        .init(jsonKey: "focusPaneOnFirstClick", defaultsKey: PaneFirstClickFocusSettings.enabledKey),
        .init(
            jsonKey: "focusHistoryIncludesPanesAndTabs",
            defaultsKey: app.focusHistoryIncludesPanesAndTabs.userDefaultsKey
        ),
        .init(
            jsonKey: "equalizeSplitsOnCreate",
            defaultsKey: app.equalizeSplitsOnCreate.userDefaultsKey
        ),
        .init(
            jsonKey: "equalizeSplitsOnDividerDoubleClick",
            defaultsKey: app.equalizeSplitsOnDividerDoubleClick.userDefaultsKey
        ),
        .init(
            jsonKey: "openSupportedFilesInCmux",
            defaultsKey: app.openSupportedFilesInCmux.userDefaultsKey
        ),
        .init(
            jsonKey: "openMarkdownInCmuxViewer",
            defaultsKey: app.openMarkdownInCmuxViewer.userDefaultsKey
        ),
        .init(jsonKey: "reorderOnNotification", defaultsKey: app.reorderOnNotification.userDefaultsKey),
        .init(jsonKey: "iMessageMode", defaultsKey: IMessageModeSettings.key),
        .init(
            jsonKey: "sendAnonymousTelemetry",
            defaultsKey: app.sendAnonymousTelemetry.userDefaultsKey
        ),
        .init(
            jsonKey: "warnBeforeClosingTab",
            defaultsKey: app.warnBeforeClosingTab.userDefaultsKey
        ),
        .init(
            jsonKey: "warnBeforeClosingAgentSession",
            defaultsKey: app.warnBeforeClosingAgentSession.userDefaultsKey
        ),
        .init(
            jsonKey: "warnBeforeClosingTabXButton",
            defaultsKey: app.warnBeforeClosingTabXButton.userDefaultsKey
        ),
        .init(
            jsonKey: "warnBeforeClosingWorkspace",
            defaultsKey: app.warnBeforeClosingWorkspace.userDefaultsKey
        ),
        .init(
            jsonKey: "alwaysConfirmWorkspaceClose",
            defaultsKey: app.alwaysConfirmWorkspaceClose.userDefaultsKey
        ),
        .init(
            jsonKey: "warnBeforeClosingWindow",
            defaultsKey: app.warnBeforeClosingWindow.userDefaultsKey
        ),
        .init(
            jsonKey: "hideTabCloseButton",
            defaultsKey: app.hideTabCloseButton.userDefaultsKey
        ),
        .init(
            jsonKey: "renameSelectsExistingName",
            defaultsKey: app.renameSelectsExistingName.userDefaultsKey
        ),
        .init(
            jsonKey: "commandPaletteSearchesAllSurfaces",
            defaultsKey: app.commandPaletteSearchesAllSurfaces.userDefaultsKey
        ),
    ]

    static let stringSettings: [SettingsFileStringMapping] = [
        .init(jsonKey: "goToWorkspaceOrder", defaultsKey: app.goToWorkspaceOrder.userDefaultsKey),
        .init(jsonKey: "preferredEditor", defaultsKey: app.preferredEditor.userDefaultsKey),
        .init(jsonKey: "defaultWorkspacePath", defaultsKey: app.defaultWorkspacePath.userDefaultsKey),
    ]
}
