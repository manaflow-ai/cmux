import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudTunnel
import CmuxNextCompat
import CmuxNextSettings
import Foundation

// `cmux cloud tunnel on|off|status` (and MCP's app_cloud_tunnel_*): the opt-in Cloud Tunnel
// (plans/cmux-next/cloud-tunnel-DESIGN.md). On and off change `cloud.tunnel.enabled`, the one
// path Settings also takes (CloudTunnelSettingSync); when the setting already holds the value
// they retry the controller directly. Each answers the status it settles in.
extension CloudHandlers {
    static func bindSystemTunnelActions(into registry: ActionRegistry, context: AppActionContext,
                                        signedIn: @escaping @MainActor () -> String?, reason: @escaping @MainActor () -> String?) {
        bind("cloudSystemTunnelOn", registry, reason: signedIn) { invocation in
            setSystemTunnel(true, invocation, context)
        }
        bind("cloudSystemTunnelOff", registry, reason: reason) { invocation in
            setSystemTunnel(false, invocation, context)
        }
        bind("cloudSystemTunnelStatus", registry, reason: reason) { invocation in
            answer("Cloud Tunnel status", invocation, context) {
                systemTunnelAnswer(context.services.cloud.systemTunnel.status)
            }
        }
    }

    private static func setSystemTunnel(_ on: Bool, _ invocation: ActionInvocation, _ context: AppActionContext) {
        let tunnel = context.services.cloud.systemTunnel
        let settings = context.services.settings
        // Approval in System Settings can take the person a while: answer then, keep going.
        answer(on ? "turn on Cloud Tunnel" : "turn off Cloud Tunnel", invocation, context, pendingAfter: .seconds(30),
               pending: ["status": .string(CloudTunnelStatus.connecting.name)]) {
            if case .unavailable(let why) = tunnel.status { throw ActionFailure(message: why) }
            let current = settings.map { CloudTunnelSetting().enabled(in: $0.snapshot.root) } ?? false
            if let settings, current != on {
                try await settings.set(.bool(on), at: CloudTunnelSetting.enabledPath)
            } else if on {
                await tunnel.enable()
            } else {
                await tunnel.disable()
            }
            for await status in ObservationStream({ tunnel.status }) where settled(status, on: on) {
                return systemTunnelAnswer(status)
            }
            return systemTunnelAnswer(tunnel.status)
        }
    }

    /// Whether `status` is where a turn-on or turn-off ends (or waits for the person).
    private static func settled(_ status: CloudTunnelStatus, on: Bool) -> Bool {
        switch status {
        case .awaitingApproval, .connected: on
        case .off: !on
        case .failed, .unavailable: true
        case .connecting, .disconnecting: false
        }
    }

    private static func systemTunnelAnswer(_ status: CloudTunnelStatus) -> CloudAnswer {
        var fields: [String: ActionResultValue] = ["status": .string(status.name)]
        if let reason = status.reason { fields["reason"] = .string(reason) }
        if case .connected(let since?) = status { fields["connected_since"] = .int(Int(since.timeIntervalSince1970)) }
        return CloudAnswer(title: CloudTunnelText.title, text: CloudTunnelText.describe(status), fields: fields)
    }
}

/// What the Cloud Tunnel actions say. Keys live in Resources/Cloud.xcstrings.
struct CloudTunnelText {
    static var title: String {
        String(localized: "cloudTunnel.title", defaultValue: "Cloud Tunnel", table: "Cloud", bundle: .module)
    }

    static func describe(_ status: CloudTunnelStatus) -> String {
        switch status {
        case .off:
            String(localized: "cloudTunnel.describe.off", defaultValue: "Off. Other apps on this Mac cannot reach your Cloud machines.", table: "Cloud", bundle: .module)
        case .unavailable(let reason), .failed(let reason):
            reason
        case .awaitingApproval:
            String(localized: "cloudTunnel.describe.awaitingApproval",
                   defaultValue: "Allow the cmux network extension in System Settings > General > Login Items & Extensions. The tunnel starts right after.",
                   table: "Cloud", bundle: .module)
        case .connecting:
            String(localized: "cloudTunnel.describe.connecting", defaultValue: "Connecting…", table: "Cloud", bundle: .module)
        case .connected:
            String(localized: "cloudTunnel.describe.connected", defaultValue: "On. Every app on this Mac can reach your Cloud machines' private addresses.", table: "Cloud", bundle: .module)
        case .disconnecting:
            String(localized: "cloudTunnel.describe.disconnecting", defaultValue: "Turning off…", table: "Cloud", bundle: .module)
        }
    }
}
