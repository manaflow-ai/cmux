import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The native UI adapter for Settings and palette updates. The owner chooses
/// commands, journals creation and reports terminal outcomes.
@MainActor
final class AgentCLIUpdateActions {
    typealias JSONValue = CmuxNextSettings.JSONValue
    struct Route {
        let machine: ResourceID
        let session: ResourceID
        let isCurrent: @MainActor () -> Bool
        let inventory: @MainActor () async throws -> AcpmuxHarnessInventory
        let start: @MainActor (AgentCLIFamily, String) async throws -> AgentCLIJobReceipt
        let observe: @MainActor (AgentCLIJobReceipt) async throws -> AgentCLIJobStatus
    }

    private let capture: @MainActor (ActionInvocation) throws -> Route

    init(capture: @escaping @MainActor (ActionInvocation) throws -> Route) {
        self.capture = capture
    }

    func bind(into registry: ActionRegistry) {
        registry.bind("agent.harness.updateAll", run: { _ in
            throw ActionFailure(message: AgentHarnessStrings.unsupported)
        })
    }

    /// Settings uses the same registry handler, with the host's context and
    /// operation id kept outside page-controlled arguments.
    func runSettings(id: String?, context: PageCallContext, registry: ActionRegistry) async throws -> JSONValue {
        throw PageError.unavailable(AgentHarnessStrings.unsupported)
    }

    /// Explicit refresh observes retained terminals, never starts a new update.
    func refresh() async {}

    var state: JSONValue { .array([]) }
}
