import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextWindowRules

/// Shared routing and page-action plumbing for Session Info screen sharing.
/// App code supplies native chat facts and the one target resolver it owns.
public struct ScreenShareAction {
    private let localMachineID: String
    private let showsInApp: (String) -> Bool

    public init(localMachineID: String, showsInApp: @escaping (String) -> Bool) {
        self.localMachineID = localMachineID
        self.showsInApp = showsInApp
    }

    public func run(
        registry: ActionRegistry,
        session: String,
        actualSession: String,
        machineID: String,
        kind: String,
        host: String,
        hostKind: String,
        peer: String?,
        registryHost: String?,
        localSummaryCurrent: Bool,
        unavailable: String,
    ) -> AgentPaneActionRun {
        let chat = WindowRules.ScreenShareChat(expectedSessionId: session, sessionId: actualSession, host: host, hostKind: hostKind,
                                               peer: peer, registryHost: registryHost, localSummaryCurrent: localSummaryCurrent)
        guard let route = WindowRules().screenShare(machineID: machineID, kind: kind, chat: chat) else { return .refused(unavailable) }
        let action: ActionID
        let target: ActionTargetRef
        switch route.decision {
        case "shareLocal": action = "macScreen.shareThisMac"; target = .init(kind: .machine, id: localMachineID)
        case "cloudDesktop":
            guard let machine = route.machineId else { return .refused(unavailable) }
            action = "cloudOpenDesktop"; target = .init(kind: .machine, id: machine)
        default: return .refused(unavailable)
        }
        return registry.runPageAction(action, invocation: .init(target: target, origin: .user), showsInApp: showsInApp)
    }

    public func runPageAction(
        registry: ActionRegistry,
        id: String,
        arguments: [String: String],
        machine: String,
        target: () -> ActionTargetRef?,
        screenShare: () -> AgentPaneActionRun,
    ) -> AgentPaneActionRun {
        if id == "session.screenShare" { return screenShare() }
        guard let target = target() else { return .notRun }
        return registry.runPageAction(ActionID(rawValue: id), invocation: ActionInvocation(target: target, arguments: arguments.mapValues(ActionValue.string), origin: .user).onMachine(target.kind == .tab ? machine : nil), showsInApp: showsInApp)
    }
}
