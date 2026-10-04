import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
@testable import CmuxNextPalette
import Testing

/// An app's companion workspace (`kind` "app_tabs", `app`, and
/// `extra.default_title` while its name is the store's default) shows
/// "<App name> Tabs" in the user's language through the one display-name
/// path, so the sidebar, the window title and the palette agree; a rename
/// (default_title false) or a custom title wins.
@MainActor
@Suite(.serialized) struct AppTabsTitleTests {
    static let key = "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a02"

    private func snapshot(_ fields: String) throws -> WorkspaceSnapshot {
        let json = #"{"id":1,"key":"\#(Self.key)","screens":[{"id":4,"layout":{"type":"leaf","pane":3},"panes":[{"id":3,"tabs":[{"surface":5}]}]}],\#(fields)}"#
        return try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
    }

    private func workspace(_ fields: String, titles: (String) -> String? = { $0 == "cmux/home" ? "Accueil Tabs" : nil }) throws -> WorkspaceModel {
        let store = DaemonStore()
        store.titles.appTabs = { titles($0) }
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [try snapshot(fields)]))
        return try #require(store.workspaces.first)
    }

    private let companion = #""name":"Home Tabs","kind":"app_tabs","app":"cmux/home","extra":{"default_title":true}"#

    @Test func aDefaultNamedCompanionShowsTheLocalizedTitle() throws {
        let w = try workspace(companion)
        #expect(w.kind == WorkspaceTitles.appTabsKind)
        #expect(w.app == "cmux/home")
        #expect(w.defaultTitle)
        #expect(w.displayName == "Accueil Tabs")
    }

    @Test func aRenameOrACustomTitleWins() throws {
        #expect(try workspace(#""name":"Scratch","kind":"app_tabs","app":"cmux/home","extra":{"default_title":false}"#).displayName == "Scratch")
        #expect(try workspace(#""name":"Scratch","kind":"app_tabs","app":"cmux/home""#).displayName == "Scratch")
        #expect(try workspace(companion + #","title":"Mine""#).displayName == "Mine")
    }

    @Test func otherWorkspacesAndUnknownAppsKeepTheirName() throws {
        #expect(try workspace(#""name":"Home Tabs","kind":"normal","app":"cmux/home","extra":{"default_title":true}"#).displayName == "Home Tabs")
        #expect(try workspace(#""name":"Mail Tabs","kind":"app_tabs","app":"mail","extra":{"default_title":true}"#).displayName == "Mail Tabs")
    }

    @Test func theTitleFormatIsLocalized() {
        #expect(AppsAppStrings.tabsWorkspace("Accueil") == "Accueil Tabs")
    }

    /// The app installs its resolver on the local store; an app the
    /// registry does not list keeps the stored name.
    @Test func theAppInstallsItsResolver() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.apps.installWorkspaceTitles()
        #expect(services.machines.local.store.titles.appTabs != nil)
        #expect(services.apps.appTabsTitle("not-installed") == nil)
        #expect(services.apps.homeDisplayName == "Home")
    }

    /// The palette's workspace entry and the window title read the same
    /// display name as the sidebar.
    @Test func thePaletteAndTheWindowTitleUseTheLocalizedTitle() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        let store = services.daemon.store
        store.titles.appTabs = { $0 == "cmux/home" ? AppsAppStrings.tabsWorkspace("Accueil") : nil }
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [try snapshot(companion)]))
        let palette = PaletteSourcesBridge.WorkspaceSource(services: services).workspaces
        #expect(palette.map(\.title) == ["Accueil Tabs"])
        let window = try #require(services.windows.openWindow(workspaces: [Self.key]))
        defer { window.window?.close() }
        services.windows.select(Self.key, in: window.state)
        for _ in 0..<1000 where window.root.titlebar.title != "Accueil Tabs" { await Task.yield() }
        #expect(window.root.titlebar.title == "Accueil Tabs")
    }
}
