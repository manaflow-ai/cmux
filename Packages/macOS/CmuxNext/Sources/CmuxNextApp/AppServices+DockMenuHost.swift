import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextAgentPane

// The Dock icon's menu (DockMenuController): one-line forwards to the paths Cmd-I and a session link take.
extension AppServices: DockMenuHost {
    func dockMenuHarnesses() async -> [AcpmuxHarnessRow] { (try? await QuitAgents.environment(self)?.harnessRows()) ?? [] }
    func dockMenuMachines() async -> [AgentChatDestinations.Destination] { await AgentChatDestinations(services: self).load() }
    func dockMenuShowWindow() -> Bool {
        guard windows.controllers.isEmpty else { return false }
        windows.reopenOrCreateWindow()
        return true
    }
    func dockMenuNewChat(_ arguments: [String: ActionValue]) { _ = registry.perform("palette.newAgentChat", invocation: ActionInvocation(arguments: arguments, origin: .user)) }
    func dockMenuOpenChat(_ id: String) { do { try DeepLinkNavigator(services: self).open(DeepLink(.session(id, turn: nil)), background: false, asking: false) } catch { registry.refuse(String(describing: error)) } }
}
