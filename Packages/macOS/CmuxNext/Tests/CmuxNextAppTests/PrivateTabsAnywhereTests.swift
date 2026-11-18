import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Private tabs anywhere (Leo, 2026-11-18: "why should private/nonprivate tabs not mix? what if in chrome you could
/// simply have an incognito tab?", then "drop the 9/30 rule and allow private tabs anywhere": "yes"). A private tab
/// (`extra.private` on its record, `private-tabs-v1`) sits in a normal window between normal tabs and is incognito
/// there alone; a single tab may leave an incognito window (the daemon marks it private), and a private tab may go
/// into one. A normal tab still never goes into an incognito window.
@MainActor @Suite(.serialized)
struct PrivateTabsAnywhereTests {
    /// A normal workspace whose one pane holds three browser tabs (normal, private, normal), and an incognito window's
    /// workspace (its `ephemeral` flag) with one browser tab.
    @MainActor struct Fixture {
        let services: AppServices
        let normalPane, incognitoPane: PaneModel
        private let keys: (normal: WorkspaceKey, secret: WorkspaceKey)

        static func page(_ surface: UInt64, _ url: String = BrowserTabService.incognitoPlaceholderURL) -> TabSnapshot {
            TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .browser, url: url, browserRenderer: "frontend")
        }

        /// The two workspaces, with `more` at the end of the normal pane.
        func tree(more: [TabSnapshot] = []) -> DaemonTree { Self.tree(keys, more: more) }

        static func tree(_ keys: (normal: WorkspaceKey, secret: WorkspaceKey), more: [TabSnapshot]) -> DaemonTree {
            func workspace(_ n: UInt64, key: WorkspaceKey, name: String, tabs: [TabSnapshot]) -> WorkspaceSnapshot {
                let pane = PaneSnapshot(id: PaneID(rawValue: n), tabs: tabs)
                return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: n), key: key, name: name,
                                         screens: [ScreenSnapshot(id: ScreenID(rawValue: n), layout: .leaf(pane.id), panes: [pane])])
            }
            return DaemonTree(workspaces: [
                workspace(1, key: keys.normal, name: "normal", tabs: [Self.page(1, "https://left.example/"), Self.page(2), Self.page(3, "https://right.example/")] + more),
                workspace(11, key: keys.secret, name: "secret", tabs: [Self.page(11)]),
            ])
        }

        init() throws {
            services = IncognitoSurfacesTests.services()
            keys = (normal: WorkspaceKey.generate(), secret: WorkspaceKey.generate())
            services.daemon.store.apply(snapshot: Self.tree(keys, more: []))
            let workspaces = services.daemon.store.workspaces
            try #require(workspaces.count == 2)
            workspaces[1].applyState(ephemeral: true, status: nil, screenGroups: nil)
            normalPane = try #require(workspaces[0].screens.first?.panes.first)
            incognitoPane = try #require(workspaces[1].screens.first?.panes.first)
            try #require(normalPane.tabs.count == 3 && incognitoPane.tabs.count == 1)
            // The middle tab's record says private, as the daemon writes it for `new-frontend-browser-tab {private: true}`.
            normalPane.tabs[1].applyState(SessionStateMirror.TabRecord(isPrivate: true), progress: nil)
            try #require(!services.windows.isIncognito(workspace: workspaces[0]) && services.windows.isIncognito(workspace: workspaces[1]))
        }
    }

    @Test func aPrivateTabBetweenTwoNormalTabsReadsIncognitoAndItsNeighboursDoNot() throws {
        let fixture = try Fixture()
        let services = fixture.services, browserTabs = services.cache.browserTabs
        let tabs = fixture.normalPane.tabs
        #expect(tabs.map { browserTabs.isIncognitoTab($0.id) } == [false, true, false])
        // Its pages use the incognito session's store, in a normal window; its neighbours keep the normal one.
        let session = services.windows.incognitoProfile()
        #expect(services.browserProfiles.engineProfile(forTab: tabs[1].id) == session)
        #expect(services.browserProfiles.engineProfile(forTab: tabs[0].id) != session)
        #expect(services.browserProfiles.engineProfile(forTab: tabs[2].id) != session)
        #expect(services.windows.hasPrivateTabs(), "a private tab in a normal window does not keep the incognito session")
    }

    /// New Private Tab's open: the create carries `private`, and the new tab reads private before its record says so.
    @Test func aTabOpenedIncognitoInANormalPaneIsPrivateFromItsCreate() async throws {
        let fixture = try Fixture()
        let browserTabs = fixture.services.cache.browserTabs
        final class Sent { var marks: [Bool] = [] }
        let sent = Sent()
        browserTabs.create = { _, _, url, _, _, _, _, _, isPrivate in
            sent.marks.append(isPrivate)
            #expect(url == BrowserTabService.incognitoPlaceholderURL, "a private tab's URL went to the daemon record")
            return SurfaceID(rawValue: 4)
        }
        _ = try await browserTabs.open(BrowserEngineChoice(engine: .webkit), in: fixture.normalPane, url: "https://secret.example/", incognito: true)
        _ = try await browserTabs.open(BrowserEngineChoice(engine: .webkit), in: fixture.normalPane, url: "https://open.example/")
        #expect(sent.marks == [true, false])
        // The daemon reports the new tab before its record's `extra.private`.
        fixture.services.daemon.store.apply(snapshot: fixture.tree(more: [Fixture.page(4)]))
        let opened = try #require(fixture.normalPane.tabs.last)
        #expect(opened.surface == SurfaceID(rawValue: 4) && browserTabs.isIncognitoTab(opened.id))
        #expect(browserTabs.startURL(for: opened) == "https://secret.example/")
    }

    /// The 2026-09-30 refusal no longer holds a single tab: a tab moves out of an incognito window into a normal one
    /// (it stays private), and a private tab of a normal window moves into an incognito one.
    @Test func movingAPrivateTabAcrossWindowKindsIsNotRefused() throws {
        let fixture = try Fixture()
        let services = fixture.services
        let incognitoTab = try #require(fixture.incognitoPane.tabs.first)
        let privateTab = fixture.normalPane.tabs[1], normalTab = fixture.normalPane.tabs[0]
        #expect(!services.crossesIncognito(incognitoTab, to: fixture.normalPane), "a tab of an incognito window may not move into a normal one")
        #expect(!services.crossesIncognito(privateTab, to: fixture.incognitoPane), "a private tab may not move into an incognito window")
        #expect(!services.crossesIncognito(normalTab, to: fixture.normalPane))
        // A normal tab keeps the refusal: its page keeps its normal store, and the incognito window's close would end it.
        #expect(services.crossesIncognito(normalTab, to: fixture.incognitoPane))
        #expect(!TabMoves.refusesIncognitoCrossing(incognitoTab, to: fixture.normalPane, services: services))
    }
}
