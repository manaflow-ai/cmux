import CmuxNextActions
import CmuxNextDaemon
import CmuxNextRemoteLocalhost
import CmuxNextRemoteLocalhostService
import CmuxNextSettings
import CmuxNextWakeups
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

extension RemoteLocalhostService {
    /// The app's remote localhost (`AppServices.remoteLocalhost`), made on first use (a remote
    /// machine's browser tab: its route, store or loopback chip; a machine browser; a remote
    /// machine's connection), never in init. It takes the current settings in
    /// the turn it is made, so its first route follows them.
    static func made(for services: AppServices) -> RemoteLocalhostService {
        let made = services.machines.makeRemoteLocalhost(following: services.settings, mainWork: services.mainWork)
        services.madeRemoteLocalhost = made
        return made
    }
}

extension MachineRegistry: RemoteLocalhostMachines {
    /// The remote localhost service of these machines (`AppServices.remoteLocalhost`), following
    /// `browser.remoteLocalhost*` when the settings exist (`AppServices.settings` follows a later one).
    func makeRemoteLocalhost(following settings: SettingsController?, mainWork: MainWorkScheduler) -> RemoteLocalhostService {
        let service = RemoteLocalhostService(machines: self, mainWork: mainWork)
        if let settings { service.follow(settings) }
        return service
    }

    /// Whether a tab of `daemon` at `url` can have a machine chip (a loopback page whose route may
    /// not be this Mac): asked before the remote localhost is made, so a tab strip of other pages,
    /// or of this Mac's, makes none.
    func mayHaveLocalhostBadge(_ url: URL?, daemon: DaemonService) -> Bool {
        url.flatMap(LoopbackHost.init(url:))?.isLoopback == true && !RemoteLocalhostService.routesToThisMac(daemon)
    }

    func personalAddress(ofWorkspace id: String) -> (session: String, key: String)? {
        WindowProfiles.qualified(id, machines: self).map { ($0.session, $0.key) }
    }
}
