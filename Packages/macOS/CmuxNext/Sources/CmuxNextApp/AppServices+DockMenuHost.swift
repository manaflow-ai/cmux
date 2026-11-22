import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextAgentPane

// The Dock icon's menu (DockMenuController): one-line forwards to the paths Cmd-I and a session link take.
extension AppServices: DockMenuHost {
    func dockMenuHarnesses() async -> [AcpmuxHarnessRow] { (try? await AcpmuxEnvironment.resolvedApp(build: environment.build, mock: environment.showcase)?.harnessRows()) ?? [] }
    func dockMenuMachines() async -> [AgentChatDestinations.Destination] { await AgentChatDestinations(services: self).load() }
    var dockMenuWindow: DockMenuWindow { windows.controllers.isEmpty ? .closed : windows.active?.workspaceContent?.modelPanes.isEmpty == false ? .pane : .noPane }
    func dockMenuReopenWindow() { windows.reopenOrCreateWindow() }
    func dockMenuNewChat(_ arguments: [String: ActionValue]) { _ = registry.perform("palette.newAgentChat", invocation: ActionInvocation(arguments: arguments, origin: .user)) }
    func dockMenuOpenChat(_ id: String) throws { try DeepLinkNavigator(services: self).open(DeepLink(.session(id, turn: nil)), background: false, asking: false) }
    func dockMenuRefuse(_ reason: String) { registry.refuse(reason) }
}
