import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextDaemonService
import CmuxNextDesign

/// The App's forwards for the catalog request rows (CmuxNextDaemonService `CatalogRequestHandlers`).
extension AppServices: CatalogRequestHost {
    var catalogDaemon: DaemonService { activeDaemon }
    var catalogControlRouter: ControlRouter? { apps.controlRouter }
    func catalogAcpmux() async -> AcpmuxEnvironment? { await AcpmuxEnvironment.resolvedApp(build: environment.build, mock: environment.showcase) }
    func catalogWorkspace(_ invocation: ActionInvocation) -> String? { AppActions.scope(self, invocation).workspace?.resourceID?.rawValue }
    func catalogPane(_ invocation: ActionInvocation) -> String? { AppActions.scope(self, invocation).pane?.pane.resourceID?.rawValue }
    func catalogToast(_ message: String) { CmuxToastCenter.shared.showNotice(message, id: "catalogRequest", in: windows.active?.window) }
}
