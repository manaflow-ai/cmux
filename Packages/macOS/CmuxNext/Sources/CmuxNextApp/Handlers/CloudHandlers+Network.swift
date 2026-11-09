import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextRemote
import CmuxNextWakeups

extension CloudHandlers {
    static func bindNetworkActions(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        // The tunnel, network and firewall actions called classic cmux.com's /api/vm routes, deleted
        // from NEXT; cmux-platform serves none of them yet, so each is unavailable and says so at once.
        let notYet: @MainActor () -> String? = { CloudStrings.notOnThisCloudYet }
        for id: ActionID in ["cloudTunnelAttach", "cloudTunnelDetach", "cloudTunnelRotateKey", "cloudNetworkList",
                             "cloudFirewallList", "cloudFirewallGet", "cloudFirewallCreate", "cloudFirewallDelete"] {
            bind(id, registry, reason: notYet) { _ in throw ActionFailure(message: CloudStrings.notOnThisCloudYet) }
        }
        bind("cloudSetNetworkAccess", registry, reason: reason) { invocation in
            try CloudNetworkAccessActions.set(invocation, context)
        }
    }

    /// The id an action takes in `--path`; `missing` names which id and
    /// where to find one (not the file-path refusal).
    static func idArgument(_ invocation: ActionInvocation, _ missing: String) throws -> String {
        guard let value = invocation["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { throw ActionFailure(message: missing) }
        return value
    }
}
