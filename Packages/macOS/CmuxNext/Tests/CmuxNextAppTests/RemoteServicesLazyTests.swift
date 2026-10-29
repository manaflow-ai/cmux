import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextRemoteLocalhostService
@testable import CmuxNextSettings
import Foundation
import Testing

/// SSH, the remote localhost and the remote-terminal service are made on first use,
/// never in `AppServices.init` or at action binding; made late, each still gets what init gave it
/// (the policy, the install offer, the settings, the session observation), so a restored
/// remote-terminal tab reconnects.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)))
struct RemoteServicesLazyTests {
    /// Launch makes none, and neither do this Mac's pages: a local Chromium page's store and
    /// guard (`configureBrowser`, every Chromium page a restore mounts) and a local loopback chip.
    @Test func theAppMakesNoRemoteServiceAtLaunch() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.madeSSH == nil, "init or binding made SSH")
        #expect(services.madeRemoteLocalhost == nil, "init or binding made the remote localhost")
        #expect(services.madeRemoteTerminals == nil, "init or binding made the remote-terminal service")
        #expect(services.browserMachineBadge(key: "no-such-tab", url: URL(string: "https://example.com")) == nil)
        #expect(services.madeRemoteLocalhost == nil, "a page that is not loopback made the remote localhost")

        let url = try #require(URL(string: "http://localhost:3000/"))
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 4_221), kind: .browser, url: url.absoluteString,
                                       browserRenderer: "frontend", browserEngine: "cef"))
        let configure = try #require(services.cache.configureBrowser, "no browser configuration hook")
        let configured = await configure(tab, url, BrowserTabConfiguration(id: BrowserTabID(rawValue: tab.id), profile: .default, initialURL: url))
        #expect(configured?.machineStore == nil, "this Mac's loopback page got a machine store")
        #expect(configured?.navigationGuard == BrowserNavigationGuard.none, "this Mac's page got a navigation guard")
        #expect(services.localhostRoute(for: tab, engine: .cef) == .thisMac)
        #expect(services.madeRemoteLocalhost == nil, "a Chromium page of this Mac made the remote localhost")
    }

    @Test func sshMadeLateTakesTheCurrentPolicyAndTheInstallOffer() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.registry.disabledFeatures = [.remoteHosts]
        let ssh = services.ssh
        #expect(services.madeSSH === ssh, "a second read makes a second SSHService")
        #expect(ssh.policyDisabled, "remote hosts were turned off before SSH was made")
        #expect(ssh.offerInstall != nil, "no install offer: remote.install never asks")
    }

    /// The remote localhost made by a remote tab's first route routes that tab by cmux.json in the
    /// same turn: `browser.remoteLocalhost` off keeps a remote machine's localhost page on this Mac
    /// ("This Mac (turned off)"), not on the fallback's forwarded route to the machine.
    @Test func theFirstRouteOfAServiceMadeLateFollowsTheSettings() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-remote-lazy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "cmux.json")
        try Data(#"{"browser":{"remoteLocalhost":false}}"#.utf8).write(to: file)
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: file,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        try #require(settings.snapshot.remoteLocalhost.isEnabled(workspace: nil) == false, "cmux.json did not turn remote localhost off")
        services.settings = settings
        #expect(services.madeRemoteLocalhost == nil, "the settings made the remote localhost")
        let id = try TabMachineColorTests.sshMachine(services.machines).machineID
        let remote = try #require(services.machines.anyDaemon(machine: id), "the SSH machine has no daemon")

        // One turn: the getter makes the service, and its first route reads the setting.
        let route = services.remoteLocalhost.route(daemon: remote, workspace: nil, engine: .cef)
        guard case .thisMacInstead(_, .turnedOff) = route else {
            Issue.record("the first route used the fallback setting, not cmux.json: \(route)")
            return
        }
        #expect(services.madeRemoteLocalhost != nil)
    }

    /// A restored window that shows a remote-terminal tab makes the service through the app's own
    /// path (the restore's first mount of the pane), attaches the terminal, and attaches it again
    /// when its machine drops and comes back. The test reads only `madeRemoteTerminals` and the
    /// cache, never the making getter, so no read of its own makes the service.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aRestoredRemoteTerminalTabReconnectsWhenItsMachineComesBack() async throws {
        try await CrossMachineTabMoveTests.withMachines { world in
            let machine = world.machine.daemon
            let session = try #require(machine.identity?.sessionID, "the other machine has no session id")
            let there = try await world.machineTab { $0.kind == .pty && $0.terminalID != nil }
            let ref = RemoteTerminalRef(sessionID: session, terminalID: try #require(there.terminalID), sessionName: "lazy-remote")
            let surface = try await world.macConnection.newRemoteTerminalTab(ref, in: world.macPane.handle).surface
            let tab = try await world.macTab { $0.surface == surface && $0.kind == .remoteTerminal }

            // Quit and launch again: the new app restores this Mac's window with the tab shown.
            let (app, again) = world.relaunch()
            #expect(app.madeRemoteTerminals == nil, "the relaunched app made the remote-terminal service before its restore")
            // Local functions are not isolated by the closure they sit in: they read the app's windows.
            @MainActor func shownPanes() -> [PaneController] {
                app.windows.controllers.compactMap(\.content).flatMap { $0.panes.values }.filter { $0.currentTabKey == tab.id }
            }
            @MainActor func attached() -> Bool { app.cache.existingTerminal(tab.id) != nil }
            try await PinnedPageTests.until({ !shownPanes().isEmpty }, within: .seconds(60), report: {
                let shown = app.windows.controllers.compactMap(\.content).flatMap { $0.panes.values }.map { $0.currentTabKey ?? "-" }
                return "the restored window does not show the remote-terminal tab \(tab.id); panes show \(shown)"
            })
            #expect(app.madeRemoteTerminals != nil, "the restored pane showed the tab without the service")
            try await PinnedPageTests.until({ attached() }, within: .seconds(60), report: { "the restored remote-terminal tab never attached" })
            let made = try #require(app.madeRemoteTerminals)

            again.daemon.shutdownConnection()
            try await PinnedPageTests.until({ !attached() },
                                            report: { "the gone machine's terminal is still mounted: the service follows no session" })

            let socket = world.machineSocket
            again.daemon.start(remote: { socket })
            try await PinnedPageTests.until({ attached() }, within: .seconds(60), report: { "the tab did not reconnect when its machine came back" })
            #expect(app.madeRemoteTerminals === made, "the service was made twice")
        }
    }
}
