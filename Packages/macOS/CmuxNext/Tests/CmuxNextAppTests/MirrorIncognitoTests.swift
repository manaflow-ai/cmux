import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
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

        /// A strip controller of `pane` (no window).
        func controller(of pane: PaneModel) throws -> PaneController {
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
            return PaneController(pane: pane, daemon: services.daemon, layoutPaneID: LayoutPaneID(pane.id), services: services, state: WindowState(record: record))
        }

        /// The mirror items of `pane`'s strip after `holder`'s browser tab is mirrored into it.
        func mirrorItems(of pane: PaneModel, mirroring holder: PaneModel) throws -> [StripTabItem] {
            let tab = try #require(holder.tabs.first)
            try #require(PaneController.mirrorable(tab))
            services.tabMirrors.add(tab.id, to: pane.id)
            let controller = try controller(of: pane)
            defer { controller.teardown() }
            return controller.mirrorItems(hiding: [])
        }

        /// Gives `holder`'s browser tab a live page (a page tab with no web view) and records its mirror in `pane`, as a
        /// request before the workspace's incognito flag came would. Returns the tab id.
        func recordMirrorWithLivePage(of holder: PaneModel, in pane: PaneModel) throws -> String {
            let tab = try #require(holder.tabs.first)
            _ = services.cache.install(HistoryPageTab(id: BrowserTabID(rawValue: tab.id), engine: .webkit, profile: .default, webPage: nil), for: tab.id)
            services.tabMirrors.add(tab.id, to: pane.id)
            return tab.id
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

    /// The request itself (`browser.page.mirror`, the Home mirror of a tab an agent drives) is refused across the kinds and
    /// records no mirror. It fails closed: a pane or a tab the app can not place records no mirror.
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
        #expect(await !services.mirror(tab: normal, into: "pane:404", select: false), "a mirror into a pane the app does not have was recorded")
        #expect(await !services.mirror(tab: "surface:404", into: fixture.normalOther.id, select: false), "a mirror of a tab the app does not have was recorded")
        #expect(services.tabMirrors["pane:404"].isEmpty && services.tabMirrors[fixture.normalOther.id] == [normal])
    }

    /// A mirror that is recorded across the kinds (its workspace's incognito flag came after the request) presents no page,
    /// and no reader of the recorded list names it: the control topology (`mirrored_tabs`, which `browser.page` targets read)
    /// and the agent cursor's place.
    @Test func aRecordedMirrorAcrossTheKindsPresentsAndNamesNothing() throws {
        let fixture = try Fixture()
        let services = fixture.services
        let secret = try fixture.recordMirrorWithLivePage(of: fixture.incognitoPage, in: fixture.normalOther)
        defer { services.cache.browsers[secret] = nil }
        let controller = try fixture.controller(of: fixture.normalOther)
        defer { controller.teardown() }
        #expect(controller.mirrorItems(hiding: []).isEmpty, "a normal window's strip lists an incognito tab with a live page")
        #expect(services.controlPageFacts.mirroredTabs(fixture.normalOther).isEmpty, "the control topology names an incognito tab in a normal window's pane")
        let shown = try #require(services.daemon.store.workspaces.first).id
        #expect(AgentCursorSnapshotBuilder.mirror(of: secret, inWorkspace: shown, content: nil, services) == nil, "the agent cursor of an incognito tab is placed in a normal window")
        #expect(controller.mirroredContent(for: secret) == nil, "a normal window's pane presents an incognito page")
    }

    /// The control of the test above: inside one kind the recorded mirror presents the tab's page and its readers name it.
    @Test func aRecordedMirrorInsideOneKindPresentsAndIsNamed() throws {
        let fixture = try Fixture()
        let services = fixture.services
        let normal = try fixture.recordMirrorWithLivePage(of: fixture.normalPage, in: fixture.normalOther)
        defer { services.cache.browsers[normal] = nil }
        let controller = try fixture.controller(of: fixture.normalOther)
        defer { controller.teardown() }
        #expect(controller.mirrorItems(hiding: []).map(\.id.rawValue) == [normal])
        #expect(services.controlPageFacts.mirroredTabs(fixture.normalOther) == [normal])
        let shown = try #require(services.daemon.store.workspaces.first).id
        #expect(AgentCursorSnapshotBuilder.mirror(of: normal, inWorkspace: shown, content: nil, services)?.pane == fixture.normalOther.id)
        #expect(controller.mirroredContent(for: normal) != nil, "a mirror inside one kind presents no page")
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
