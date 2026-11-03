import CmuxNextActions
import CmuxNextCloudTunnel
import CmuxNextSettings
import Foundation

// `cmux cloud tunnel on|off|status` (and MCP): the opt-in Cloud Tunnel
// (plans/cmux-next/cloud-tunnel-DESIGN.md). On and off change `cloud.tunnel.enabled`, the path
// Settings also takes (CloudTunnelController.follow), and ask the controller for the status the
// change settles in (a second request for the same direction joins the first).
extension CloudHandlers {
    static func bindSystemTunnelActions(into registry: ActionRegistry, context: AppActionContext,
                                        signedIn: @escaping @MainActor () -> String?, reason: @escaping @MainActor () -> String?) {
        bind("cloudSystemTunnelOn", registry, reason: signedIn) { setSystemTunnel(true, $0, context) }
        bind("cloudSystemTunnelOff", registry, reason: reason) { setSystemTunnel(false, $0, context) }
        bind("cloudSystemTunnelStatus", registry, reason: reason) { invocation in
            answer("Cloud Tunnel status", invocation, context) { systemTunnelAnswer(context.services.cloud.systemTunnel.status) }
        }
    }

    private static func setSystemTunnel(_ on: Bool, _ invocation: ActionInvocation, _ context: AppActionContext) {
        let tunnel = context.services.cloud.systemTunnel
        let settings = context.services.settings
        // Approval in System Settings can take the person a while: answer then, keep going.
        answer(on ? "turn on Cloud Tunnel" : "turn off Cloud Tunnel", invocation, context, pendingAfter: .seconds(30),
               pending: ["status": .string((on ? CloudTunnelStatus.connecting : .disconnecting).name)]) {
            // Like the setting's agent policy (.network): an agent cannot open the Mac to the Cloud network.
            if on, ![.user, .cli].contains(invocation.origin) { throw ActionFailure(message: CloudTunnelStatus.agentRefusal) }
            if case .unavailable(let why) = tunnel.status { throw ActionFailure(message: why) }
            if let settings, CloudTunnelSetting().enabled(in: settings.snapshot.root) != on {
                try await settings.set(.bool(on), at: CloudTunnelSetting.enabledPath)
            }
            return systemTunnelAnswer(await tunnel.request(on: on))
        }
    }

    private static func systemTunnelAnswer(_ status: CloudTunnelStatus) -> CloudAnswer {
        var fields: [String: ActionResultValue] = ["status": .string(status.name)]
        if let reason = status.reason { fields["reason"] = .string(reason) }
        if case .connected(let since?) = status { fields["connected_since"] = .int(Int(since.timeIntervalSince1970)) }
        return CloudAnswer(title: CloudTunnelStatus.title, text: status.summary, fields: fields)
    }
}
