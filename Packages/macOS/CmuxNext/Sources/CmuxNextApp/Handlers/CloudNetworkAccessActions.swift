import CmuxNextActions
import CmuxNextCloud
import Foundation

/// Internet Access… (`cloud set-network-access`): a machine's outbound network level over the
/// server's stored policy (`GET`/`PUT /api/vm/{id}/network`, web/services/vms/networkPolicy.ts).
/// Its own type, beside ``CloudHandlers`` whose machine lookup and result helpers it uses.
@MainActor
enum CloudNetworkAccessActions {
    /// `cloud set-network-access --target machine:<id> --access full|trusted|none`. It reads the
    /// stored policy, changes only its mode (and, for `trusted`, adds the server's presets), and
    /// writes it back, so the machine's own ranges and domains stay. An agent's run that would
    /// choose anything but `none` is refused: an agent may close its machine off, never open it up. A CLI, agent
    /// or script run gets `machine_id`, `network_access`, `mode` and `applied` back; a person's run
    /// reports a failure in a sheet.
    static func set(_ invocation: ActionInvocation, _ context: AppActionContext,
                    read: @escaping @MainActor (String) async throws -> CloudNetworkPolicyState,
                    write: @escaping @MainActor (String, CloudNetworkPolicy) async throws -> CloudNetworkPolicyState) throws {
        let session = try CloudHandlers.machine(invocation, context)
        // The policy lives on the web control plane (`/api/vm`); the app server link's machines have none yet.
        guard context.services.cloud.configuration.linkSource == .legacy else { throw unavailable }
        let access = try level(invocation)
        // The run's effective origin counts: an action an MCP run nests carries a .user origin of its own.
        let machineID = session.machineID, isAgent = CloudStartSession.isAgent(invocation)
        // An agent may only choose `none`: the PUT replaces the policy unconditionally, so a level
        // judged against a read that a person's newer edit (the dashboard, another Mac) made stale
        // could reopen what they closed. `none` is the narrowest whatever the server holds by then.
        // Lifting this needs a conditional PUT on the server (#28706).
        let work: @MainActor () async throws -> [String: ActionResultValue] = { try await context.services.cloud.networkAccess.serialized(machineID) {
            if isAgent, access != .noInternet { throw ActionFailure(message: CloudStrings.networkAccessAgentWidens) }
            let current = try await read(machineID)
            let policy = access.applied(to: current.policy, presets: current.presets.map(\.id))
            // The same policy is written again unless it is applied: a PUT retries a failed apply.
            if policy == current.policy, current.applied?.state == "applied" { return fields(machineID, current) }
            return fields(machineID, try await write(machineID, policy))
        } }
        guard CloudHandlers.origin(of: invocation) == .user else { return CloudHandlers.result("set network access", context, work) }
        CloudHandlers.runTracked("set network access", context) { _ = try await work() }
    }

    /// The same refusal (and key) as the other Cloud machine actions a machine's backend can't do.
    static var unavailable: ActionFailure {
        ActionFailure(message: String(localized: "cloud.operationUnavailable",
            defaultValue: "This action is unavailable for this Cloud machine.", bundle: .module))
    }

    /// The `access` argument: one of ``CloudNetworkAccess``'s raw values.
    static func level(_ invocation: ActionInvocation) throws -> CloudNetworkAccess {
        let text = invocation["access"]?.stringValue?.trimmingCharacters(in: .whitespaces).lowercased()
        guard let text, let access = CloudNetworkAccess(rawValue: text) else {
            throw ActionFailure(message: CloudStrings.networkAccessMustBeOneOf(CloudNetworkAccess.allCases.map(\.rawValue).joined(separator: ", ")))
        }
        return access
    }

    /// The stored policy as result fields: `network_access` is `custom` for an allowlist a person
    /// built by hand (in the dashboard's editor).
    static func fields(_ machineID: String, _ state: CloudNetworkPolicyState) -> [String: ActionResultValue] {
        let level = CloudNetworkAccess.level(of: state.policy, presets: state.presets.map(\.id))
        var fields: [String: ActionResultValue] = [
            "machine_id": .string(machineID), "mode": .string(state.policy.mode.rawValue),
            "network_access": .string(level?.rawValue ?? "custom"),
        ]
        if let applied = state.applied {
            fields["applied"] = .string(applied.state)
            if let error = applied.error { fields["applied_error"] = .string(error) }
        }
        return fields
    }
}
