import CmuxNextActions
import CmuxNextBridge

/// The object a confirmed action acts on, resolved from focus BEFORE its confirmation
/// shows (cx-zk9t). The confirmation names it, and the confirmed run carries it as the
/// invocation's target, so a focus change while the dialog shows (another window
/// activated by automation) never moves the action to another object.
enum ActionTargetPin {
    /// The target and its display name, for an invocation without an explicit target;
    /// nil when the action takes none or nothing is focused.
    static func resolve(_ id: ActionID, _ invocation: ActionInvocation, _ services: AppServices) -> (ActionTargetRef, String)? {
        guard invocation.target == nil, let kind = services.registry.descriptor(for: id)?.targets.first else { return nil }
        let context = AppActionContext(services: services)
        switch kind {
        case .machine:
            if id.rawValue.hasPrefix("remote.") {
                guard let session = try? RemoteHandlers.machine(invocation, context) else { return nil }
                return (ActionTargetRef(kind: .machine, id: session.machineID), session.host.label)
            }
            guard let session = try? CloudHandlers.machine(invocation, context) else { return nil }
            return (ActionTargetRef(kind: .machine, id: session.machineID), session.machine.displayName ?? session.machineID)
        case .workspace:
            guard let workspace = context.scope(invocation).workspace else { return nil }
            return (ActionTargetRef(kind: .workspace, id: workspace.id), workspace.displayName)
        case .tab:
            guard let tab = context.scope(invocation).tab else { return nil }
            return (ActionTargetRef(kind: .tab, id: tab.id.rawValue), tab.pane.tab(tab.id)?.displayTitle ?? tab.id.rawValue)
        case .tabGroup:
            guard let group = context.scope(invocation).tabGroupID else { return nil }
            return (ActionTargetRef(kind: .tabGroup, id: group), group)
        default:
            return nil
        }
    }
}
