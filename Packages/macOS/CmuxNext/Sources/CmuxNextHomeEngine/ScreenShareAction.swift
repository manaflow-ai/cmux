import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextWindowRules

/// Routes a Session Info screen-share intent after the App has resolved its tab facts.
/// The App remains a composition root: it supplies facts and the existing action registry.
public enum ScreenShareAction {
    public static func run(
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
        case "shareLocal": action = "macScreen.shareThisMac"; target = .init(kind: .machine, id: MachineRegistry.localID)
        case "cloudDesktop":
            guard let machine = route.machineId else { return .refused(unavailable) }
            action = "cloudOpenDesktop"; target = .init(kind: .machine, id: machine)
        default: return .refused(unavailable)
        }
        return registry.runPageAction(action, invocation: .init(target: target, origin: .user), showsInApp: CmuxSignInOffer.signInReasons.contains)
    }
}
