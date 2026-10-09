import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import Testing

/// cx-2cob slice 1a: Cmd-Shift-L (and every other path through
/// `BrowserTabService`) in a workspace of another machine did nothing: the
/// service sent the new tab to the LOCAL daemon, which has no such pane, and
/// only logged the failure. Pane and surface handles are per daemon (both
/// trees here have pane 3), so the pane's own daemon must take the request.
@MainActor
struct RemotePaneBrowserTabTests {
    static let remoteWorkspace = "7d0e3c1a-2b4f-4c6d-8e9f-a0b1c2d3e4f5"

    static func remoteTree() throws -> DaemonTree {
        let tab = #"{"kind":"browser","name":"","surface":19,"dead":false,"browser_renderer":"frontend","browser_engine":"webkit","url":"https://remote.example/"}"#
        let json = """
        {"generation":"g1","workspace_revision":1,"workspaces":[{"active":true,"id":1,"key":"\(remoteWorkspace)","name":"r",
        "screens":[{"active":true,"id":2,"layout":{"pane":3,"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":3,"name":null,
        "tabs":[\(tab)]}]}]}]}
        """
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }

    struct Fixture {
        let services: AppServices
        let machine: SSHMachineSession
        let localPane: PaneModel
        let remotePane: PaneModel
    }

    static func fixture() throws -> Fixture {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: try BrowserRecordMoveTests.tree(pane: 3, tab: BrowserRecordMoveTests.tab))
        let host = try SSHHost(destination: SSHDestination(parsing: "dev@build-box.local"), session: "main")
        let paths = SSHPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("rpb-\(UUID().uuidString)"))
        let machine = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"), paths: paths, environment: { [:] })
        services.machines.add(machine)
        machine.daemon.store.apply(snapshot: try remoteTree())
        let localPane = try #require(services.daemon.store.pane(PaneID(rawValue: 3)))
        let remotePane = try #require(machine.daemon.store.pane(PaneID(rawValue: 3)))
        return Fixture(services: services, machine: machine, localPane: localPane, remotePane: remotePane)
    }

    @Test func aNewTabInARemotePaneGoesToThatMachinesDaemon() async throws {
        let f = try Self.fixture()
        let browserTabs = f.services.cache.browserTabs
        var targets: [(DaemonService, PaneID)] = []
        browserTabs.create = { daemon, pane, _, _, _, _, _ in
            targets.append((daemon, pane))
            return SurfaceID(rawValue: 40)
        }
        let choice = BrowserEngineChoice(engine: .webkit)
        _ = try await browserTabs.open(choice, in: f.remotePane, url: "https://google.com/")
        _ = try await browserTabs.open(choice, in: f.localPane, url: "https://google.com/")
        #expect(targets.count == 2)
        #expect(targets.first?.0 === f.machine.daemon, "the remote pane's tab goes to its machine")
        #expect(targets.last?.0 === f.services.daemon)
        #expect(targets.allSatisfy { $0.1 == PaneID(rawValue: 3) })
        withExtendedLifetime(f.services) {}
    }

    @Test func aTabOpenedInARemotePaneSaysItRunsOnThisMac() async throws {
        let f = try Self.fixture()
        let browserTabs = f.services.cache.browserTabs
        browserTabs.create = { daemon, _, _, _, _, _, _ in SurfaceID(rawValue: daemon === f.services.daemon ? 41 : 19) }
        let choice = BrowserEngineChoice(engine: .webkit)
        _ = try await browserTabs.open(choice, in: f.remotePane, url: "https://google.com/")
        let remoteTab = try #require(f.remotePane.tabs.first)
        let notice = try #require(browserTabs.takeNotice(for: remoteTab))
        #expect(notice == RemoteStrings.browserRunsOnThisMac(f.machine.host.label))
        _ = try await browserTabs.open(choice, in: f.localPane, url: "https://google.com/")
        #expect(browserTabs.takeNotice(for: try #require(f.localPane.tabs.first)) == nil, "this Mac's own tabs need no notice")
        withExtendedLifetime(f.services) {}
    }

    /// Live check (m1max, ffcob-v1): the new tab's page (the New Tab page)
    /// existed before `open` returned, so the pending notice was never shown.
    /// A page that already exists takes the notice at once.
    @Test func aPageThatAlreadyExistsShowsTheNoticeAtOnce() async throws {
        let f = try Self.fixture()
        let browserTabs = f.services.cache.browserTabs
        browserTabs.create = { _, _, _, _, _, _, _ in SurfaceID(rawValue: 19) }
        var shown: [(String, SurfaceID, String)] = []
        browserTabs.showNotice = { daemon, surface, text in
            shown.append((daemon.machineID, surface, text))
            return true
        }
        _ = try await browserTabs.open(BrowserEngineChoice(engine: .webkit), in: f.remotePane, url: "https://google.com/")
        #expect(shown.map(\.2) == [RemoteStrings.browserRunsOnThisMac(f.machine.host.label)])
        #expect(shown.first?.0 == f.machine.machineID && shown.first?.1 == SurfaceID(rawValue: 19))
        #expect(browserTabs.takeNotice(for: try #require(f.remotePane.tabs.first)) == nil, "shown once, not again at page creation")
        withExtendedLifetime(f.services) {}
    }

    /// The page made for the tab later shows the notice on its chrome.
    @Test func theTabsPageShowsTheNoticeOnItsChrome() async throws {
        let f = try Self.fixture()
        let browserTabs = f.services.cache.browserTabs
        browserTabs.create = { _, _, _, _, _, _, _ in SurfaceID(rawValue: 19) }
        _ = try await browserTabs.open(BrowserEngineChoice(engine: .webkit), in: f.remotePane, url: "https://google.com/")
        let remoteTab = try #require(f.remotePane.tabs.first)
        let entry = try #require(f.services.cache.browser(for: remoteTab))
        #expect(entry.chrome.noticeText == RemoteStrings.browserRunsOnThisMac(f.machine.host.label))
        withExtendedLifetime(f.services) {}
    }

    /// Live check (ffcob-v3, a Cloud machine whose cmux-tui lacks
    /// frontend-browser-tabs-v1): Cmd-Shift-L only showed a refusal. A
    /// connected machine without daemon browser tabs gets this Mac's
    /// session-local tab instead (no refusal), and that tab's page says it
    /// runs on this Mac.
    @Test func aSessionLocalTabCarriesTheNoticeByItsKey() throws {
        let f = try Self.fixture()
        let browserTabs = f.services.cache.browserTabs
        browserTabs.setNotice("runs here", forKey: "local-browser-1")
        #expect(browserTabs.takeNotice(forKey: "local-browser-1") == "runs here")
        #expect(browserTabs.takeNotice(forKey: "local-browser-1") == nil, "once")
        #expect(PaneBrowserTabOpener.machineRoute(isLocal: false, connected: true, servesTabs: false) == .sessionLocal)
        #expect(PaneBrowserTabOpener.machineRoute(isLocal: false, connected: false, servesTabs: false) == .refuseNotConnected)
        #expect(PaneBrowserTabOpener.machineRoute(isLocal: false, connected: true, servesTabs: true) == .daemon)
        #expect(PaneBrowserTabOpener.machineRoute(isLocal: true, connected: false, servesTabs: false) == .sessionLocal)
        withExtendedLifetime(f.services) {}
    }

    /// cx-whr7: the page notice sits under a Chromium page's child window,
    /// so the omnibar carries it: a "This Mac" chip on a tab of another
    /// machine's tree that runs here (never on this Mac's own tabs, never on
    /// a machine browser record, which runs there).
    @Test func theOmnibarSaysThisMacForATabOfAnotherMachine() throws {
        let f = try Self.fixture()
        let remoteTab = try #require(f.remotePane.tabs.first)
        let localTab = try #require(f.localPane.tabs.first)
        let badge = try #require(f.services.browserMachineBadge(key: remoteTab.id, url: URL(string: "https://www.google.com/")))
        #expect(badge.text == MachineBrowserStrings.thisMac)
        #expect(badge.help == RemoteStrings.browserRunsOnThisMac(f.machine.host.label))
        #expect(f.services.browserMachineBadge(key: localTab.id, url: URL(string: "https://www.google.com/")) == nil)
        let record = MachineBrowserRecord(machine: f.machine.machineID, initialURL: nil).url
        #expect(f.services.browserMachineBadge(key: remoteTab.id, url: record) == nil)
        withExtendedLifetime(f.services) {}
    }

    /// The This Mac chip's menu offers the machine (Open on <machine>);
    /// this Mac's own tabs have no such menu.
    @Test func theThisMacChipOffersOpenOnTheMachine() throws {
        let f = try Self.fixture()
        let remoteTab = try #require(f.remotePane.tabs.first)
        let menu = try #require(f.services.machineBadgeMenu(key: remoteTab.id))
        #expect(menu.items.map(\.title) == [MachineBrowserStrings.openOn(f.machine.host.label)])
        #expect(f.services.machineBadgeMenu(key: try #require(f.localPane.tabs.first).id) == nil)
        #expect(f.services.cache.browserTabs.browserHostAvailable(f.machine.machineID) == false, "no machine has a browser host yet")
        withExtendedLifetime(f.services) {}
    }

    @Test func aDisconnectedMachineRefusesWithItsNameInsteadOfDoingNothing() throws {
        let f = try Self.fixture()
        let refusal = try #require(f.services.cache.browserTabs.refusal(in: f.remotePane))
        #expect(refusal == RemoteStrings.browserMachineNotConnected(f.machine.host.label))
        withExtendedLifetime(f.services) {}
    }

    @Test func tabLookupsAndWritesUseTheTabsOwnMachine() throws {
        let f = try Self.fixture()
        let browserTabs = f.services.cache.browserTabs
        let remoteTab = try #require(f.remotePane.tabs.first)
        #expect(browserTabs.tabModel(remoteTab.id) === remoteTab, "a remote tab is found by id")
        #expect(browserTabs.daemon(for: remoteTab) === f.machine.daemon)
        let localTab = try #require(f.localPane.tabs.first)
        #expect(browserTabs.daemon(for: localTab) === f.services.daemon)
        withExtendedLifetime(f.services) {}
    }

    @Test func profilesAndIncognitoReadTheRemotePanesWorkspace() throws {
        let f = try Self.fixture()
        let browserTabs = f.services.cache.browserTabs
        let work = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
        try f.services.browserProfiles.edit { try $0.create(id: work, name: "Work", color: nil, icon: nil) }
        let localWorkspace = try #require(f.services.daemon.store.workspaces.first)
        try f.services.browserProfiles.setWorkspaceDefault(work, for: localWorkspace.id)
        #expect(browserTabs.resolveProfile(f.localPane, nil) == work)
        #expect(browserTabs.resolveProfile(f.remotePane, nil) == "default", "the remote pane is not the local pane with the same handle")
        withExtendedLifetime(f.services) {}
    }
}
