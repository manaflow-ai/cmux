import CmuxNextActions
import CmuxNextCloud
import Foundation

/// Internet Access… (`cloud set-network-access`): a machine's outbound network level. The Cloud app
/// server's machines have no network policy yet, so the action names the machine and refuses.
/// Its own type, beside ``CloudHandlers`` whose machine lookup it uses.
@MainActor
enum CloudNetworkAccessActions {
    /// `cloud set-network-access --target machine:<id> --access full|trusted|none`: refused with
    /// ``unavailable`` once the machine is found.
    static func set(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
        _ = try CloudHandlers.machine(invocation, context)
        throw unavailable
    }

    /// The same refusal (and key) as the other Cloud machine actions a machine's backend can't do.
    static var unavailable: ActionFailure {
        ActionFailure(message: String(localized: "cloud.operationUnavailable",
            defaultValue: "This action is unavailable for this Cloud machine.", bundle: .module))
    }
}
