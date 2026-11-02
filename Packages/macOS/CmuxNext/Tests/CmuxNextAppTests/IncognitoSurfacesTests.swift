import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCloud
import CmuxNextControl
@testable import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextSidebar
import Foundation
import Testing

/// What an incognito window holds stays out of the places that outlive it (leo-workspace design/spaces.md
/// "Incognito": nothing of it is kept, and normal and incognito content never mix; spaces-incognito-audit
/// leaks 5, 6 and 9): Notification Center's history, the files the quit writes for the next launch, and
/// normal windows' space bars and sidebar snapshots.
@MainActor @Suite(.serialized)
struct IncognitoSurfacesTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        return services
    }

    // MARK: Leak 5: banners

    /// The banner the app posts for a finished agent turn in workspace "secret-project", which is an incognito
    /// window's when `incognito`.
    func banner(incognito: Bool) throws -> DesktopNotifier.Posted? {
        let services = Self.services()
        var key = WorkspaceKey.generate()
        if incognito {
            let window = services.windows.newIncognitoWindow()
            key = WorkspaceKey(rawValue: try #require(services.windows.claims.pending.first { $0.value == window }?.key))
        }
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7", name: "deploy keys")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: key, name: "secret-project", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        let paneModel = try #require(workspace.screens.first?.panes.first)
        let located = LocatedTab(tab: try #require(paneModel.tabs.first), pane: paneModel, workspace: workspace)
        let wire = #"{"notification":5,"title":"Claude finished","subtitle":"rotated the prod key","body":"","preview":"Rotated the production signing key.","level":"info","surface":1,"source":"agent"}"#
        let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))
        let service = NotificationCenterService()
        service.services = services
        service.screenLocked = { false }
        var decision = NotificationPolicy.Decision()
        decision.desktop = true
        service.deliver(notification, source: .agent, located: located, decision: decision, program: nil)
        return service.desktop.posted.last
    }

    @Test func anIncognitoBannerNamesNothingOfTheWindow() throws {
        let posted = try #require(try banner(incognito: true), "an incognito arrival posted no banner at all")
        let shown = [posted.title, posted.subtitle ?? "", posted.body].joined(separator: " | ")
        for secret in ["secret-project", "deploy keys", "Claude finished", "prod key", "signing key"] {
            #expect(!shown.contains(secret), "Notification Center keeps \"\(secret)\" from an incognito window: \(shown)")
        }
        #expect(posted.title == DesktopNotifier.incognitoTitle)
        #expect(posted.body == DesktopNotifier.incognitoBody)
        #expect(posted.subtitle == nil && posted.attachment == nil && !posted.approval)
    }

    @Test func aNormalBannerIsUnchanged() throws {
        let posted = try #require(try banner(incognito: false))
        #expect(posted.title.hasPrefix("secret-project"))
        #expect(posted.body == "Rotated the production signing key.")
    }

    /// An agent's passkey request from an incognito browser tab names neither the agent nor the site; one
    /// from a normal window's tab does. The tab resolves on its own machine and its window is read from
    /// its pane (#28382), so the check works on the real tab tree, not on a by-id stand-in.
    @Test func anIncognitoPasskeyBannerNamesNothing() async throws {
        let services = Self.services()
        let window = services.windows.newIncognitoWindow()
        let secret = WorkspaceKey(rawValue: try #require(services.windows.claims.pending.first { $0.value == window }?.key))
        func workspace(_ id: UInt64, _ key: WorkspaceKey, tab: String) -> WorkspaceSnapshot {
            let page = TabSnapshot(surface: .init(rawValue: id), tabResourceID: ResourceID(rawValue: tab), kind: .browser, url: "https://bank.example")
            let pane = PaneSnapshot(id: .init(rawValue: id), tabs: [page])
            return WorkspaceSnapshot(id: .init(rawValue: id), key: key, name: tab,
                                     screens: [ScreenSnapshot(id: .init(rawValue: id), layout: .leaf(.init(rawValue: id)), panes: [pane])])
        }
        services.daemon.store.apply(snapshot: DaemonTree(workspaces: [workspace(1, secret, tab: "tab_secret"),
                                                                      workspace(2, WorkspaceKey.generate(), tab: "tab_normal")]))
        let host = AppBrowserPasskeyHost(services: services)
        await host.post(BrowserPasskeyRequest(id: "p1", tabID: "tab_secret", agent: "Chief", site: "bank.example"))
        let posted = services.notifications.desktop.posted.last
        #expect(posted?.title == DesktopNotifier.incognitoTitle && posted?.body == DesktopNotifier.incognitoBody,
                "an incognito tab's passkey banner names its agent or site: \(String(describing: posted))")
        await host.post(BrowserPasskeyRequest(id: "p2", tabID: "tab_normal", agent: "Chief", site: "bank.example"))
        let normal = services.notifications.desktop.posted.last
        #expect(normal?.title.contains("Chief") == true && normal?.body.contains("bank.example") == true,
                "a normal window's passkey banner lost its agent or site: \(String(describing: normal))")
        // A tab closed while the request waited may have been an incognito one: its banner names nothing either.
        await host.post(BrowserPasskeyRequest(id: "p3", tabID: "tab_closed", agent: "Chief", site: "bank.example"))
        #expect(services.notifications.desktop.posted.last?.body == DesktopNotifier.incognitoBody)
    }

    /// A Run or hand-off from an incognito chat is never saved for the next launch (its task or summary
    /// included), so no later launch can post it. Only its bare id is kept while it may be open (#31040).
    @Test func incognitoRunsAreNeverSaved() async throws {
        let suite = "incognito-surfaces-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let follower = SandboxRunFollower(wait: { _, _ in throw CancellationError() }, defaults: defaults)
        follower.account("u")
        var secret = SandboxRunRecord(id: "run_secret", task: "rotate the prod key", key: "k1", user: "u", team: nil, started: Date())
        secret.incognito = true
        follower.watch(secret)
        follower.watch(SandboxRunRecord(id: "run_normal", task: "make test", key: "k2", user: "u", team: nil, started: Date()))
        let saved = String(decoding: defaults.data(forKey: SandboxRunFollower.defaultsKey) ?? Data(), as: UTF8.self)
        #expect(saved.contains("run_normal"))
        #expect(!saved.contains("prod key"), "an incognito Run was saved for the next launch")
        let relaunched = SandboxRunFollower(wait: { _, _ in throw CancellationError() }, defaults: defaults)
        #expect(relaunched.following.map(\.id) == ["run_normal"], "an incognito Run's record was saved for the next launch")
    }

    /// Issue #31208: an incognito Run is never resumed after a relaunch (its record isn't saved, and no list
    /// brings it back), so its id is dropped at the next sign-in instead of staying saved forever.
    @Test func anIncognitoRunsIDIsDroppedAtTheNextLaunchsSignIn() async throws {
        let suite = "incognito-surfaces-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func saved() -> String { String(decoding: defaults.data(forKey: SandboxRunFollower.defaultsKey) ?? Data(), as: UTF8.self) }
        let first = SandboxRunFollower(wait: { _, _ in throw CancellationError() }, defaults: defaults)
        first.account("u")
        var secret = SandboxRunRecord(id: "run_secret", task: "rotate the prod key", key: "k1", user: "u", team: nil, started: Date())
        secret.incognito = true
        first.watch(secret)
        #expect(saved().contains("run_secret"))
        first.stop()
        let relaunched = SandboxRunFollower(wait: { _, _ in throw CancellationError() }, defaults: defaults)
        relaunched.account("u")
        #expect(!saved().contains("run_secret"), "an incognito Run's id outlived the launch that could follow it")
    }

    /// The tabs the quit leaves out are taken before its window step closes the incognito workspaces (after
    /// that, a removed tab no longer reads as incognito): every chat view's tab and every held composer's.
    @Test func theQuitTakesTheIncognitoTabsUpFront() {
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(),
                                 environment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9/"], showcase: true)
        tabs.wakeStates["tab_secret"] = AgentPaneWakeState(shell: true, shellText: "cat ~/.ssh/id_ed25519")
        tabs.wakeStates["tab_normal"] = AgentPaneWakeState(shell: true, shellText: "make test")
        #expect(AgentQuitFiles.incognitoTabs(tabs, isIncognito: { $0 == "tab_secret" }) == ["tab_secret"])
    }

    // MARK: Leak 6: the quit's agent tab files

    static let thisMac = "install:incognito-surfaces-test"

    /// An incognito chat's composer (its chips and shell command) is never written for the next launch.
    @Test func theQuitKeepsNoIncognitoChatsComposer() async throws {
        let records = [
            "tab_normal": AgentSessionRef(host: Self.thisMac, hostName: "This Mac", session: "s-normal", harness: "claude"),
            "tab_secret": AgentSessionRef(host: Self.thisMac, hostName: "This Mac", session: "s-secret", harness: "claude"),
        ]
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(),
                                 environment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9/"], showcase: true)
        tabs.localHost = Self.thisMac
        let tree = DaemonStore()
        tabs.lookup = { key in records[key].map { ($0, tree) } }
        tabs.wakeStates["tab_normal"] = AgentPaneWakeState(shell: true, shellText: "make test")
        tabs.wakeStates["tab_secret"] = AgentPaneWakeState(shell: true, shellText: "cat ~/.ssh/id_ed25519")
        let saved = await AgentQuitFiles.composers(tabs, isIncognito: { $0 == "tab_secret" })
        #expect(saved["tab_normal"]?.shellText == "make test")
        #expect(saved["tab_secret"] == nil, "the quit saved an incognito chat's composer for the next launch")
    }

    // MARK: Leak 9: the space bar

    /// A normal window's space bar (and so its sidebar snapshot) never lists an incognito space; the incognito
    /// window still shows its own. The space is marked before the daemon mirrors it, so no frame lists it.
    @Test func normalWindowsNeverListTheIncognitoSpace() {
        let services = Self.services()
        let work = ProfileID(rawValue: "prof_work"), secret = ProfileID(rawValue: "prof_incognito_bar")
        services.machines.local.store.profiles = [ProfileModel(ProfileSnapshot(id: work, name: "Work")),
                                                  ProfileModel(ProfileSnapshot(id: secret, name: "Incognito", index: 1))]
        services.windows.incognitoSpaceMarks.mark(secret)
        let normal = SidebarSpaceBar.profiles(services.machines.local, window: "normal-window", windows: services.windows)
        #expect(normal.map(\.name) == ["Work"], "a normal window's space bar lists the incognito space")
        let window = services.windows.newIncognitoWindow(space: secret)
        let own = SidebarSpaceBar.profiles(services.machines.local, window: window, windows: services.windows)
        #expect(own.map(\.name).contains("Incognito"), "the incognito window lost its own space")
        #expect(SidebarSpaceBar.profiles(services.machines.local, window: "normal-window", windows: services.windows).map(\.name) == ["Work"])
    }

    @Test func spacesLeaveOutTheHiddenOnes() {
        let store = DaemonStore()
        store.profiles = [ProfileModel(ProfileSnapshot(id: ProfileID(rawValue: "a"), name: "A")),
                          ProfileModel(ProfileSnapshot(id: ProfileID(rawValue: "b"), name: "B", index: 1))]
        #expect(SidebarMapping.spaces(store, image: { _ in nil }, hiding: ["b"]).map(\.name) == ["A"])
        #expect(SidebarMapping.spaces(store, image: { _ in nil }).map(\.name) == ["A", "B"])
    }
}
