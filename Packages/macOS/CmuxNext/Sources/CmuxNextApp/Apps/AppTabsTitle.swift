import CmuxNextDaemon

/// The title of an app's companion workspace (app-screens.md 2): new tabs
/// sent to an app workspace land in an ordinary workspace right after it,
/// which the store marks `kind` "app_tabs" with `app`, and
/// `extra.default_title` while its name is the store's default. The app
/// shows "<App name> Tabs" in the user's language for it, through the one
/// display-name path (`WorkspaceModel.displayName`, `WorkspaceTitles`).
extension AppsService {
    /// "<App name> Tabs" for `appID`, or nil while the registry does not
    /// list it (the stored name shows). Reads the registry under observation.
    func appTabsTitle(_ appID: String) -> String? {
        registry.app(appID).map { AppsAppStrings.tabsWorkspace($0.manifest.name.resolved()) }
    }

    /// Gives the local store this app's titles for default-named app
    /// companion workspaces.
    func installWorkspaceTitles() {
        services.machines.local.store.titles.appTabs = { [weak self] appID in self?.appTabsTitle(appID) }
    }

    /// The Home app's English name, sent with `workspace.ensure_home` so the
    /// store names Home's companion workspace for the CLI and TUI.
    var homeDisplayName: String {
        registry.app(Self.homeAppID)?.manifest.name.english ?? "Home"
    }

    static let homeAppID = "cmux/home"
}
