import CmuxNextActions
import CmuxNextWindowRules

/// Shared routing and page-action plumbing for Session Info screen sharing.
/// App code supplies native chat facts and the one target resolver it owns.
public struct ScreenShareAction {
    public enum Result: Equatable, Sendable {
        case ran
        case refused(String)
        case notRun
    }
    public typealias Perform = (ActionID, ActionTargetRef, [String: String], String?) -> Result

    private let localMachineID: String

    public init(localMachineID: String) {
        self.localMachineID = localMachineID
    }

    public func run(
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
        perform: @escaping Perform,
    ) -> Result {
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
        return perform(action, target, [:], nil)
    }

    public func runPageAction(
        id: String,
        arguments: [String: String],
        machine: String,
        target: () -> ActionTargetRef?,
        screenShare: () -> Result,
        perform: @escaping Perform,
    ) -> Result {
        if id == "session.screenShare" { return screenShare() }
        guard let target = target() else { return .notRun }
        return perform(ActionID(rawValue: id), target, arguments, target.kind == .tab ? machine : nil)
    }
}
