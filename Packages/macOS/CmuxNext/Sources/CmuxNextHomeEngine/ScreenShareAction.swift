public import CmuxNextActions
public import CmuxNextAgentPane
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
        screenDeviceID: String? = nil,
        device: WindowRules.ScreenShareDevice? = nil,
    ) -> AgentPaneActionRun {
        let unavailable = Self.unavailable
        let chat = WindowRules.ScreenShareChat(expectedSessionId: session, sessionId: actualSession, host: host, hostKind: hostKind,
                                               peer: peer, registryHost: registryHost, localSummaryCurrent: localSummaryCurrent)
        guard let route = WindowRules().screenShare(machineID: machineID, kind: kind, chat: chat,
                                                    authenticatedDeviceID: screenDeviceID, device: device) else { return .refused(unavailable) }
        let action: ActionID
        let invocation: ActionInvocation
        switch route.decision {
        case "shareLocal": action = "macScreen.shareThisMac"; invocation = .init(target: .init(kind: .machine, id: localMachineID), origin: .user)
        case "cloudDesktop":
            guard let machine = route.machineId else { return .refused(unavailable) }
            action = "cloudOpenDesktop"; invocation = .init(target: .init(kind: .machine, id: machine), origin: .user)
        // A joined Mac or Linux machine: its screen, as the palette's "Screen Sharing: NAME" row opens it.
        case "viewDevice":
            guard let device = route.deviceId else { return .refused(unavailable) }
            action = "macScreen.open"; invocation = .init(arguments: ["device": .string(device)], origin: .user)
        default: return .refused(route.reason == "offline" ? Self.offline : unavailable)
        }
        return registry.runPageAction(action, invocation: invocation, showsInApp: showsInApp)
    }

    /// Why Session Info's Share or View screen did nothing for the chat's machine.
    public static var unavailable: String {
        String(localized: "screenShare.chat.unavailable", defaultValue: "Screen sharing is not available for this chat’s machine. Open Machines to check its connection.", table: "Home", bundle: .module)
    }

    static var offline: String {
        String(localized: "screenShare.chat.offline", defaultValue: "This chat’s machine is offline, so its screen can’t be shown. Open Machines to check its connection.", table: "Home", bundle: .module)
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
