import CmuxNextActions
import CmuxNextDaemon
import CmuxNextRemoteLocalhostService

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

extension MachineRegistry: RemoteLocalhostMachines {
    /// The remote localhost service of these machines (`AppServices.remoteLocalhost`).
    func makeRemoteLocalhost() -> RemoteLocalhostService {
        RemoteLocalhostService(machines: self)
    }

    func personalAddress(ofWorkspace id: String) -> (session: String, key: String)? {
        WindowProfiles.qualified(id, machines: self).map { ($0.session, $0.key) }
    }
}
