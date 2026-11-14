import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextWindowRules
import Foundation

extension AgentTabStore {
    /// The Session Info gesture stays bound to this tab's recorded host and session.
    /// A peer listed by the local daemon is never treated as this Mac.
    func shareScreen(of key: AgentTabKey, session: String?) -> AgentPaneActionRun {
        guard let registry = actionRegistry, let session,
              let (record, _) = record(for: key), let daemon = daemon(for: key) else {
            return .refused(Self.screenShareUnavailable)
        }
        let host = hostKind(record, listedHere: daemon.isLocal)
        let kind: String
        let hostName: String
        switch host {
        case .local: kind = "local"; hostName = "local"
        case .chief: kind = "unsupported"; hostName = "chief"
        case .remote:
            kind = daemon.isLocal ? "remote" : (MachineRegistry.isCloudMachineID(daemon.machineID) ? "cloud" : "remote")
            hostName = "remote"
        }
        let lanes = AgentLaneStore.shared
        let links = lanes.links(session)
        let chat = WindowRules.ScreenShareChat(expectedSessionId: session, sessionId: record.session ?? "", host: record.host, hostKind: hostName,
                                               peer: links?.peer, registryHost: Self.registryHost(of: daemon),
                                               localSummaryCurrent: lanes.live && links != nil)
        guard let route = WindowRules().screenShare(machineID: daemon.machineID, kind: kind, chat: chat) else {
            return .refused(Self.screenShareUnavailable)
        }
        let action: ActionID
        let target: ActionTargetRef
        switch route.decision {
        case "shareLocal":
            action = "macScreen.shareThisMac"
            target = ActionTargetRef(kind: .machine, id: MachineRegistry.localID)
        case "cloudDesktop":
            guard let machine = route.machineId else { return .refused(Self.screenShareUnavailable) }
            action = "cloudOpenDesktop"
            target = ActionTargetRef(kind: .machine, id: machine)
        default:
            // Remote device identity comes from the Machines foundation, never an install-id guess.
            return .refused(Self.screenShareUnavailable)
        }
        return registry.runPageAction(action, invocation: ActionInvocation(target: target, origin: .user), showsInApp: CmuxSignInOffer.signInReasons.contains)
    }

    private static var screenShareUnavailable: String {
        String(localized: "screenShare.chat.unavailable", defaultValue: "Screen sharing is not available for this chat’s machine. Open Machines to check its connection.", table: "MiscHandlers", bundle: .module)
    }
}
