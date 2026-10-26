import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextLaunch
import CmuxNextRemoteLocalhost
import CmuxNextRemoteLocalhostService
import CmuxNextWakeups
import Foundation

// The remote services (SSH machines, remote localhost, remote-terminal tabs) are made on first use,
// never in `AppServices.init` (p08-startup-021, the Q1 eager builds): a launch with no remote machine
// makes none before its first frame. Chrome makes a keyed service the same way, on its first
// `GetServiceForBrowserContext` unless the factory asks for creation with the context
// (components/keyed_service/content/browser_context_keyed_service_factory.cc,
// `ServiceIsCreatedWithBrowserContext`).
extension AppServices {
    /// SSH machines, with the install offer and the organization's current policy set before any reader
    /// gets them. `SSH.start` (an afterFirstFrame post) restores the saved machines.
    func makeSSH() -> SSHService {
        let ssh = SSHService(machines: machines, bundleID: environment.launch.bundleID, mainWork: mainWork)
        madeSSH = ssh
        ssh.offerInstall = { [weak registry] session in
            // Asks through the registry's confirmation sheet (remote.install is destructive).
            _ = registry?.perform("remote.install", invocation: ActionInvocation(target: ActionTargetRef(kind: .machine, id: session.machineID)))
        }
        ssh.applyPolicy(disabled: registry.disabledFeatures.contains(.remoteHosts))
        return ssh
    }

    /// The remote localhost, following `browser.remoteLocalhost*` once the settings exist (`settings`
    /// follows it from then on).
    func makeRemoteLocalhost() -> RemoteLocalhostService {
        let localhost = machines.makeRemoteLocalhost()
        madeRemoteLocalhost = localhost
        if let settings { localhost.follow(settings) }
        return localhost
    }

    /// The remote-terminal service, following every session's connection from now on.
    func makeRemoteTerminals() -> RemoteTerminalService {
        let service = RemoteTerminalService(services: self)
        madeRemoteTerminals = service
        service.start()
        return service
    }

    /// The machine chip of browser tab `tab` at `url` (`RemoteLocalhostService.badge`). Only a loopback
    /// page has one, so a tab strip of other pages makes no remote localhost.
    func localhostBadge(for tab: TabModel, url: URL?, engine: BrowserEngineKind) -> (text: String, help: String)? {
        guard isLoopback(url) else { return nil }
        return remoteLocalhost.badge(for: tab, url: url, engine: engine)
    }

    func isLoopback(_ url: URL?) -> Bool { url.flatMap(LoopbackHost.init(url:))?.isLoopback == true }

    /// Makes the remote-terminal service after the first frame when the launch's restore shows a
    /// remote-terminal tab (`LaunchServicePosts.restoredRemoteTerminals`).
    func postRestoredRemoteTerminals(on startup: StartupScheduler) {
        windows.whenRestored { [weak self] in
            guard let self else { return }
            LaunchServicePosts.restoredRemoteTerminals(shown: showsRemoteTerminal) { [weak self] in _ = self?.remoteTerminals }
                .post(on: startup)
        }
    }

    /// A window's pane shows a remote-terminal tab.
    private var showsRemoteTerminal: Bool {
        windows.controllers.contains { controller in
            controller.content?.panes.values.contains { $0.selectedTab?.kind == .remoteTerminal } == true
        }
    }
}
