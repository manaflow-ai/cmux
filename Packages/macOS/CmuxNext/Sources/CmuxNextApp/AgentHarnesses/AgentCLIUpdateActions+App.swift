import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation

extension AgentCLIUpdateActions {
    convenience init(services: AppServices) {
        self.init(capture: { [weak services] invocation in
            guard let services else { throw DaemonError.notConnected }
            let daemon: DaemonService
            if let target = invocation.target {
                guard target.kind == .machine, let selected = services.machines.daemon(machine: target.id) else {
                    throw DaemonError.notConnected
                }
                daemon = selected
            } else {
                daemon = services.activeDaemon
            }
            return try Self.route(services: services, daemon: daemon)
        }, persistence: Persistence(record: { [weak services] inputs in
            _ = try await Self.withLedger(services: services) { try await $0.record(inputs) }
        }, list: { [weak services] in
            try await Self.withLedger(services: services) { try await $0.list() }
        }, attach: { [weak services] input, receipt in
            _ = try await Self.withLedger(services: services) { try await $0.attach(key: input.key, receipt: receipt) }
        }), captureRecovered: { [weak services] machine, session in
            guard let services, let original = services.machines.daemons.first(where: {
                $0.identity?.machineResourceID == machine && $0.identity?.sessionResourceID == session
            }) else { throw DaemonError.notConnected }
            return try Self.route(services: services, daemon: original)
        })
    }

    private static func currentRoute(services: AppServices, daemon: DaemonService) throws -> (DaemonConnection, ResourceID, ResourceID, @MainActor () -> Bool) {
        guard services.machines.daemon(machine: daemon.machineID) === daemon,
              !daemon.policyBlock.isBlocked, case .connected = daemon.store.connectionState,
              let connection = daemon.connection, let identity = daemon.identity,
              let machine = identity.machineResourceID, let session = identity.sessionResourceID else { throw DaemonError.notConnected }
        let epoch = daemon.store.connectionEpoch
        let current: @MainActor () -> Bool = { [weak services, weak daemon] in
            guard let services, let daemon else { return false }
            guard services.machines.daemon(machine: daemon.machineID) === daemon,
                  !daemon.policyBlock.isBlocked, case .connected = daemon.store.connectionState else { return false }
            return daemon.connection === connection && daemon.store.connectionEpoch == epoch
                && daemon.identity?.machineResourceID == machine && daemon.identity?.sessionResourceID == session
        }
        return (connection, machine, session, current)
    }

    private static func route(services: AppServices, daemon: DaemonService) throws -> Route {
        let (connection, machine, session, current) = try currentRoute(services: services, daemon: daemon)
        guard daemon.identity?.capabilities.contains("agent-cli-update-job-resolve-v1") == true else {
            throw DaemonError.missingCapabilities(["agent-cli-update-job-resolve-v1"])
        }
        let sideEvents = daemon.store.sideEvents
        guard let stamp = sideEvents.controlStamp, stamp.sourceID == connection.eventSourceID else { throw DaemonError.notConnected }
        var carrier: AgentCLIJobCarrier?
        // Recovery captures the same transport without inventory or acpmux work.
        let captured: @MainActor () async throws -> AgentCLIJobCarrier = {
            guard current() else { throw DaemonError.notConnected }
            if let carrier { return carrier }
            let jobs = try await connection.agentCLIJobs(expectedMachineID: machine, expectedSessionID: session)
            guard current() else { throw DaemonError.notConnected }
            carrier = jobs
            return jobs
        }
        return Route(machine: machine, session: session, isCurrent: current,
            inventory: { try await captured().inventory() },
            start: { cli, key in try await captured().startUpdate(cli: cli, idempotencyKey: key) },
            observe: { receipt in try await captured().observe(receipt) },
            resolve: { cli, key in try await captured().resolveUpdate(cli: cli, idempotencyKey: key) },
            changes: { Self.terminalChanges(sideEvents: sideEvents, stamp: stamp, current: current) })
    }

    private static func withLedger<T>(services: AppServices?, body: @MainActor (AgentCLIIntentLedger) async throws -> T) async throws -> T {
        guard let services else { throw DaemonError.notConnected }
        let (connection, machine, session, current) = try currentRoute(services: services, daemon: services.machines.local)
        let ledger = try await connection.agentCLIIntentLedger(expectedMachineID: machine, expectedSessionID: session)
        guard current() else { throw DaemonError.notConnected }
        let result = try await body(ledger)
        guard current() else { throw DaemonError.notConnected }
        return result
    }
}
