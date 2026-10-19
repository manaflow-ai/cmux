import CmuxNextDaemon
import Foundation

/// Serves admitted `agent_cli.list` calls using the app's existing machine registry.
///
/// Selection uses public machine IDs only. A read stays on its selected carrier,
/// verifies the owner there, then rechecks route admission before returning data.
/// Installation, updates, live refresh and other operations remain unsupported.
public nonisolated struct AgentCLICapabilityHandler: AppHostCapabilityHandler {
    private let routes: @MainActor @Sendable () -> [AgentInventoryRoute]
    /// The capability family supplied on the verified-app provider channel.
    public var families: Set<String> { ["agent_cli"] }

    /// Creates a read-only handler over snapshots of the app's route registry.
    /// - Parameter routes: Current routes, including their current policy decision.
    public init(routes: @escaping @MainActor @Sendable () -> [AgentInventoryRoute]) {
        self.routes = routes
    }

    /// Reads a selected admitted owner and returns an explicitly partial cached inventory.
    /// - Parameter request: The supervisor-admitted operation, params and origin.
    /// - Returns: A machine ID and partial CLI observations, with no account labels.
    /// - Throws: Unsupported operations, malformed params or machine/owner failures.
    public func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        guard request.op == "agent_cli.list" else { throw .unsupported(request.op) }
        guard let params = request.params.objectValue,
              params.keys.allSatisfy({ $0 == "machine" || $0 == "check_latest" }) else { throw invalid() }
        let wanted: String?
        if let field = params["machine"] {
            guard let machine = field.stringValue, !machine.isEmpty, machine.utf8.count <= 128 else { throw invalid() }
            wanted = machine
        } else { wanted = nil }
        if let field = params["check_latest"] {
            guard let refresh = field.boolValue else { throw invalid() }
            if refresh { throw .unsupported(request.op) }
        }
        try checkCancellation()
        let route = try select(await routes(), machine: wanted)
        try checkCancellation()
        guard let machine = route.machineID, let reader = route.reader else { throw unavailable() }
        let snapshot: AcpmuxHarnessInventory
        do {
            snapshot = try await reader.readAgentInventory(machine: machine)
        } catch is CancellationError {
            throw cancelled()
        } catch let error as DaemonError {
            if Task.isCancelled { throw cancelled() }
            if case .missingCapabilities = error { throw .unsupported(request.op) }
            if case .command(_, _, let code, _, _) = error,
               let code, ["agent_inventory.not_trusted", "agent_inventory.bad_request", "agent_inventory.owner_mismatch",
                          "agent_inventory.unavailable", "agent_inventory.unsupported", "agent_inventory.busy",
                          "agent_inventory.invalid_response"].contains(code) {
                throw AppHostCapabilityError(code: code, message: String(localized: "apps.agentCLI.inventory.unavailable", defaultValue: "The machine's cached agent inventory is unavailable", bundle: .module), retryable: code == "agent_inventory.busy")
            }
            throw unavailable(retryable: error.isLostConnection)
        } catch {
            if Task.isCancelled { throw cancelled() }
            throw unavailable()
        }
        try checkCancellation()
        let current = try select(await routes(), machine: machine.rawValue)
        try checkCancellation()
        guard let currentReader = current.reader, currentReader === reader else { throw unavailable() }
        return AgentCLIInventoryProjection(snapshot: snapshot).value(machine: machine)
    }

    private func select(_ candidates: [AgentInventoryRoute], machine: String?) throws(AppHostCapabilityError) -> AgentInventoryRoute {
        let matches = candidates.filter { candidate in
            machine.map { candidate.machineID?.rawValue == $0 } ?? candidate.isDefault
        }
        guard matches.count <= 1 else {
            throw AppHostCapabilityError(code: "machine.ambiguous", message: String(localized: "apps.agentCLI.machine.ambiguous", defaultValue: "The selected machine has more than one route", bundle: .module))
        }
        guard let route = matches.first, route.allowed, route.reader != nil,
              let id = route.machineID, !id.rawValue.isEmpty else { throw unavailable() }
        return route
    }

    private func checkCancellation() throws(AppHostCapabilityError) {
        if Task.isCancelled { throw cancelled() }
    }

    private func invalid() -> AppHostCapabilityError {
        AppHostCapabilityError(code: "validation.invalid", message: String(localized: "apps.agentCLI.validation.invalid", defaultValue: "Expected only machine and check_latest inventory parameters", bundle: .module))
    }

    private func unavailable(retryable: Bool = false) -> AppHostCapabilityError {
        AppHostCapabilityError(code: "machine.unavailable", message: String(localized: "apps.agentCLI.machine.unavailable", defaultValue: "The selected machine is unavailable", bundle: .module), retryable: retryable)
    }

    private func cancelled() -> AppHostCapabilityError {
        AppHostCapabilityError(code: "operation.cancelled", message: String(localized: "apps.agentCLI.operation.cancelled", defaultValue: "The inventory read was cancelled", bundle: .module))
    }
}
