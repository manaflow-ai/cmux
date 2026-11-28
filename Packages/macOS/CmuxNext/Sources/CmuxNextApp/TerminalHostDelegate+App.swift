import CmuxNextActions
import CmuxNextTerminal

extension TerminalHostDelegate {
    /// A Ghostty action with the app as its target (`quit`,
    /// `toggle_visibility`, `check_for_updates`, ...; libghostty sends these
    /// with no surface): the routed registry action with no target.
    func performAppAction(_ action: TerminalHostAction) -> Bool {
        services?.keyRouter.trace?("app host action \(action) -> \(TerminalHostActionRoute.route(action)?.id.rawValue ?? "no route")")
        guard let services, let route = TerminalHostActionRoute.route(action) else { return false }
        services.registry.perform(route.id, invocation: ActionInvocation(arguments: route.arguments))
        return true
    }
}
