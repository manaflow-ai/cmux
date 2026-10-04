import CmuxNextDaemon

/// The title of an app's companion workspace (app-screens.md 2): new tabs
/// sent to an app workspace land in an ordinary workspace right after it,
/// stored by the daemon as `kind` "app_tabs" with `app` and the English
/// default name "<App> Tabs". While the name is that default (and no custom
/// title is set) the app shows "<App name> Tabs" in the user's language; a
/// rename by the user wins.
enum AppTabsTitle {
    static let kind = "app_tabs"

    /// An app's English display name (the daemon's default) and its name in
    /// the user's language.
    struct AppName: Equatable {
        var english: String
        var localized: String
    }

    /// The localized title for `workspace`, or nil when it keeps its own.
    static func title(for workspace: WorkspaceModel, names: (String) -> AppName?) -> String? {
        guard workspace.kind == kind, let app = workspace.app, workspace.title?.isEmpty ?? true,
              let name = names(app), workspace.name == name.english + " Tabs" else { return nil }
        return AppsAppStrings.tabsWorkspace(name.localized)
    }
}

extension AppsService {
    /// `AppTabsTitle` names from the app registry (observed).
    func appTabsName(_ appID: String) -> AppTabsTitle.AppName? {
        registry.app(appID).map { AppTabsTitle.AppName(english: $0.manifest.name.english, localized: $0.manifest.name.resolved()) }
    }

    /// The sidebar title of `workspace` when it is an app's companion
    /// workspace with its default name.
    func appTabsTitle(_ workspace: WorkspaceModel) -> String? {
        AppTabsTitle.title(for: workspace) { appTabsName($0) }
    }
}
