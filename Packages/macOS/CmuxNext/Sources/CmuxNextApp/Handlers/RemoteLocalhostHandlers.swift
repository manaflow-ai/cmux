import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextRemoteLocalhost
import CmuxNextRemoteLocalhostService
import CmuxNextSettings
import Foundation

/// Set Workspace Localhost (`ActionRegistry.setWorkspaceLocalhost`): the App resolves the
/// workspace and shows the approval sheet.
enum RemoteLocalhostHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("workspace.setRemoteLocalhost", requires: DaemonCapability.personalRemoteLocalhost.rawValue,
                      daemon: services.machines.local, run: { invocation in
            try services.registry.setWorkspaceLocalhost(invocation, workspace: {
                let (model, _) = try context.workspace(invocation)
                return (model.id, model.displayName)
            }, machines: services.machines) { workspace, choice in
                let prompt = DestructiveConfirmation.Prompt(
                    title: ConfirmationStrings.remoteLocalhostTitle, body: ConfirmationStrings.remoteLocalhostBody(workspace, choice),
                    button: ConfirmationStrings.userOnlySettingButton)
                return await UserOnlySettingConfirmation.ask(prompt, services: services)
            }
        })
    }
}

extension AppServices {
    /// Made on first use (a browser tab's route or store, a loopback page's chip, a machine browser),
    /// never in init (p08-startup-021), as Chrome makes a keyed service on its first
    /// GetServiceForBrowserContext (components/keyed_service/content/browser_context_keyed_service_factory.cc).
    var remoteLocalhost: RemoteLocalhostService {
        if let madeRemoteLocalhost { return madeRemoteLocalhost }
        let made = machines.makeRemoteLocalhost(following: settings)
        madeRemoteLocalhost = made
        return made
    }

    /// The machine chip of browser tab `tab` at `url`: only a loopback page has one, so a tab strip of
    /// other pages makes no remote localhost.
    func localhostBadge(for tab: TabModel, url: URL?, engine: BrowserEngineKind) -> (text: String, help: String)? {
        guard let url, LoopbackHost(url: url)?.isLoopback == true else { return nil }
        return remoteLocalhost.badge(for: tab, url: url, engine: engine)
    }
}

extension MachineRegistry: RemoteLocalhostMachines {
    /// The remote localhost service of these machines (`AppServices.remoteLocalhost`), following
    /// `browser.remoteLocalhost*` when the settings exist (`AppServices.settings` follows a later one).
    func makeRemoteLocalhost(following settings: SettingsController?) -> RemoteLocalhostService {
        let service = RemoteLocalhostService(machines: self)
        if let settings { service.follow(settings) }
        return service
    }

    func personalAddress(ofWorkspace id: String) -> (session: String, key: String)? {
        WindowProfiles.qualified(id, machines: self).map { ($0.session, $0.key) }
    }
}
