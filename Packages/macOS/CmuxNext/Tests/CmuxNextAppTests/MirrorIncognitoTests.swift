import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// A pane's mirrors (`TabMirrors`: `browser.page.mirror`, and the Home mirror of a tab an agent starts to drive)
/// obey the incognito window rule (WindowManager+Incognito, user decision 2026-09-30: "Nothing moves between an
/// incognito window and a normal one"). The mirror path had no incognito check: a pane of a normal window listed
/// an incognito tab with its live title and address, and the reverse. A mirror inside the incognito kind showed
/// the daemon's placeholder record, not what the tab's own strip shows.
@MainActor @Suite(.serialized)
struct MirrorIncognitoTests {
    /// Two workspaces, each with a browser tab the app draws in one pane and a terminal in a second pane.
    /// The second workspace is an incognito window's (its `ephemeral` flag), with the placeholder record
    /// that the app makes for an incognito tab (`BrowserTabService.incognitoPlaceholderURL`, no title).
    @MainActor struct Fixture {
        let services: AppServices
        let normalPage, normalOther, incognitoPage, incognitoOther: PaneModel

        init() throws {
            services = IncognitoSurfacesTests.services()
            func workspace(_ n: UInt64, name: String, page: TabSnapshot) -> WorkspaceSnapshot {
                let panes = [PaneSnapshot(id: PaneID(rawValue: n), tabs: [page]),
                             PaneSnapshot(id: PaneID(rawValue: n + 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: n + 1), title: "shell")])]
                let screens = panes.map { ScreenSnapshot(id: ScreenID(rawValue: $0.id.rawValue), layout: .leaf($0.id), panes: [$0]) }
                return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: n), key: WorkspaceKey.generate(), name: name, screens: screens)
            }
            let normal = TabSnapshot(surface: 1, kind: .browser, title: "Normal Page", url: "https://normal.example/page", browserRenderer: "frontend")
            let incognito = TabSnapshot(surface: 11, kind: .browser, url: BrowserTabService.incognitoPlaceholderURL, browserRenderer: "frontend")
            services.daemon.store.apply(snapshot: DaemonTree(workspaces: [workspace(1, name: "normal", page: normal),
                                                                         workspace(11, name: "secret", page: incognito)]))
            let workspaces = services.daemon.store.workspaces
            try #require(workspaces.count == 2)
            workspaces[1].applyState(ephemeral: true, status: nil, screenGroups: nil)
            let panes = workspaces.flatMap { $0.screens.flatMap(\.panes) }
            try #require(panes.count == 4)
            normalPage = panes[0]
            normalOther = panes[1]
            incognitoPage = panes[2]
            incognitoOther = panes[3]
            try #require(!services.windows.isIncognito(workspace: workspaces[0]) && services.windows.isIncognito(workspace: workspaces[1]))
        }

        /// The mirror items of `pane`'s strip after `holder`'s browser tab is mirrored into it.
        func mirrorItems(of pane: PaneModel, mirroring holder: PaneModel) throws -> [StripTabItem] {
            let tab = try #require(holder.tabs.first)
            try #require(PaneController.mirrorable(tab))
            services.tabMirrors.add(tab.id, to: pane.id)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
            let controller = PaneController(pane: pane, daemon: services.daemon, layoutPaneID: LayoutPaneID(pane.id), services: services,
                                            state: WindowState(record: record))
            defer { controller.teardown() }
            return controller.mirrorItems(hiding: [])
        }
    }

    /// The fixture lists a mirror at all: a normal tab in a second pane of a normal window, with its record's title and address.
    @Test func aNormalTabsMirrorInANormalWindowShowsItsRecord() throws {
        let fixture = try Fixture()
        let items = try fixture.mirrorItems(of: fixture.normalOther, mirroring: fixture.normalPage)
        #expect(items.map(\.title) == ["Normal Page"])
        #expect(items.map(\.subtitle) == ["https://normal.example/page"])
    }

    @Test func aNormalWindowsPaneNeverListsAnIncognitoTab() throws {
        let fixture = try Fixture()
        let items = try fixture.mirrorItems(of: fixture.normalOther, mirroring: fixture.incognitoPage)
        #expect(items.isEmpty, "a normal window's strip lists an incognito tab: \(items.map { "\($0.title) | \($0.subtitle ?? "-")" })")
    }

    @Test func anIncognitoWindowsPaneNeverListsANormalTab() throws {
        let fixture = try Fixture()
        let items = try fixture.mirrorItems(of: fixture.incognitoOther, mirroring: fixture.normalPage)
        #expect(items.isEmpty, "an incognito window's strip lists a normal tab: \(items.map { "\($0.title) | \($0.subtitle ?? "-")" })")
    }

    /// The request itself (`browser.page.mirror`, the Home mirror of a tab an agent drives) is refused across the kinds:
    /// it records no mirror and selects nothing in the pane.
    @Test func aMirrorRequestAcrossTheKindsIsRefused() async throws {
        let fixture = try Fixture()
        let services = fixture.services
        let secret = try #require(fixture.incognitoPage.tabs.first).id, normal = try #require(fixture.normalPage.tabs.first).id
        #expect(await !services.mirror(tab: secret, into: fixture.normalOther.id, select: true), "an incognito tab was mirrored into a normal window")
        #expect(await !services.mirror(tab: normal, into: fixture.incognitoOther.id, select: true), "a normal tab was mirrored into an incognito window")
        #expect(services.tabMirrors[fixture.normalOther.id].isEmpty && services.tabMirrors[fixture.incognitoOther.id].isEmpty)
        #expect(await services.mirror(tab: normal, into: fixture.normalOther.id, select: false))
        #expect(await services.mirror(tab: secret, into: fixture.incognitoOther.id, select: false))
        #expect(services.tabMirrors[fixture.normalOther.id] == [normal] && services.tabMirrors[fixture.incognitoOther.id] == [secret])
    }

    /// Inside the incognito kind a mirror is allowed. It shows what the tab's own strip shows (`incognitoDisplay`:
    /// the live page, else the start address kept in memory), never the daemon's placeholder record.
    @Test func anIncognitoTabsMirrorInAnIncognitoWindowNeverShowsThePlaceholderRecord() throws {
        let fixture = try Fixture()
        let items = try fixture.mirrorItems(of: fixture.incognitoOther, mirroring: fixture.incognitoPage)
        #expect(items.count == 1)
        #expect(items.first?.title == Strings.untitledBrowser)
        #expect(items.first?.subtitle == nil, "the mirror shows the record's placeholder address: \(items.first?.subtitle ?? "-")")
    }
}
