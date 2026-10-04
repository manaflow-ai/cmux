@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// The companion workspace of an app (`kind` "app_tabs", `app` its id,
/// stored name the English "<App> Tabs") shows "<App name> Tabs" in the
/// user's language while the name is the default; a rename wins.
@MainActor
struct AppTabsTitleTests {
    private func workspace(_ fields: String) throws -> WorkspaceModel {
        let json = #"{"id":1,"key":"0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a02",\#(fields)}"#
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [snapshot]))
        return try #require(store.workspaces.first)
    }

    private func names(_ app: String) -> AppTabsTitle.AppName? {
        app == "home" ? AppTabsTitle.AppName(english: "Home", localized: "Accueil") : nil
    }

    @Test func theDefaultNameShowsTheLocalizedAppName() throws {
        let w = try workspace(#""name":"Home Tabs","kind":"app_tabs","app":"home""#)
        #expect(w.kind == AppTabsTitle.kind)
        #expect(w.app == "home")
        #expect(AppTabsTitle.title(for: w, names: names) == AppsAppStrings.tabsWorkspace("Accueil"))
        #expect(AppsAppStrings.tabsWorkspace("Accueil") == "Accueil Tabs")
    }

    @Test func aRenameOrACustomTitleWins() throws {
        #expect(AppTabsTitle.title(for: try workspace(#""name":"Scratch","kind":"app_tabs","app":"home""#), names: names) == nil)
        #expect(AppTabsTitle.title(for: try workspace(#""name":"Home Tabs","title":"Mine","kind":"app_tabs","app":"home""#),
                                   names: names) == nil)
    }

    @Test func otherWorkspacesAndUnknownAppsKeepTheirName() throws {
        #expect(AppTabsTitle.title(for: try workspace(#""name":"Home Tabs","kind":"normal","app":"home""#), names: names) == nil)
        #expect(AppTabsTitle.title(for: try workspace(#""name":"Mail Tabs","kind":"app_tabs","app":"mail""#), names: names) == nil)
        #expect(AppTabsTitle.title(for: try workspace(#""name":"Home Tabs","kind":"app_tabs""#), names: names) == nil)
    }
}
