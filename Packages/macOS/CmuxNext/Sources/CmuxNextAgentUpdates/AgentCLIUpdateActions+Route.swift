import CmuxNextActions
import CmuxNextDaemon
public import CmuxNextDaemonService

extension AgentCLIUpdateActions {
    /// The app's daemons, read when an update captures its owner.
    public struct Daemons {
        let active: @MainActor () -> DaemonService?
        let all: @MainActor () -> [DaemonService]
        let machine: @MainActor (String) -> DaemonService?

        public init(active: @escaping @MainActor () -> DaemonService?, all: @escaping @MainActor () -> [DaemonService],
                    machine: @escaping @MainActor (String) -> DaemonService?) {
            self.active = active
            self.all = all
            self.machine = machine
        }
    }

    /// The palette's target machine, else the active daemon, while the app still routes to it.
    /// Recovery reattaches only the original machine/session; the ledger is the local owner's.
    public convenience init(daemons: Daemons, unsupported: @escaping @MainActor () -> String,
                            nothingToUpdate: @escaping @MainActor () -> String,
                            stillUpdating: @escaping @MainActor (String) -> String, localMachine: String) {
        let registered: @MainActor (DaemonService) -> Bool = { daemons.machine($0.machineID) === $0 }
        let ledger: @MainActor () async throws -> (AgentCLIIntentLedger, @MainActor () -> Bool) = {
            guard let local = daemons.machine(localMachine) else { throw DaemonError.notConnected }
            let (connection, machine, session, current) = try Route.connected(local, registered: registered)
            return (try await connection.agentCLIIntentLedger(expectedMachineID: machine, expectedSessionID: session), current)
        }
        self.init(capture: { invocation in
            if let target = invocation.target {
                guard target.kind == .machine, let daemon = daemons.machine(target.id) else { throw DaemonError.notConnected }
                return try Route.capture(daemon, registered: registered)
            }
            guard let daemon = daemons.active() else { throw DaemonError.notConnected }
            return try Route.capture(daemon, registered: registered)
        }, persistence: .ledger(ledger), captureRecovered: { machine, session in
            guard let original = daemons.all().first(where: {
                $0.identity?.machineResourceID == machine && $0.identity?.sessionResourceID == session
            }) else { throw DaemonError.notConnected }
            return try Route.capture(original, registered: registered)
        }, unsupported: unsupported, nothingToUpdate: nothingToUpdate, stillUpdating: stillUpdating, localMachine: localMachine)
    }
}

extension AgentCLIUpdateActions.Persistence {
    /// The local owner's Rust ledger; each call recaptures it and rechecks the route after.
    static func ledger(_ capture: @escaping @MainActor () async throws -> (AgentCLIIntentLedger, @MainActor () -> Bool)) -> Self {
        func use<T>(_ body: @MainActor (AgentCLIIntentLedger) async throws -> T) async throws -> T {
            let (ledger, current) = try await capture()
            guard current() else { throw DaemonError.notConnected }
            let result = try await body(ledger)
            guard current() else { throw DaemonError.notConnected }
            return result
        }
        return Self(record: { inputs in _ = try await use { try await $0.record(inputs) } },
                    list: { try await use { try await $0.list() } },
                    attach: { input, receipt in _ = try await use { try await $0.attach(key: input.key, receipt: receipt) } },
                    settle: { keys in try await use { try await $0.settle(keys: keys) } })
    }
}

extension AgentCLIUpdateActions.Route {
    /// The daemon's connected connection, owner and a check that it stays the same.
    static func connected(_ daemon: DaemonService, registered: @escaping @MainActor (DaemonService) -> Bool) throws
        -> (DaemonConnection, ResourceID, ResourceID, @MainActor () -> Bool) {
        guard registered(daemon), !daemon.policyBlock.isBlocked, case .connected = daemon.store.connectionState,
              let connection = daemon.connection, let identity = daemon.identity,
              let machine = identity.machineResourceID, let session = identity.sessionResourceID else {
            throw DaemonError.notConnected
        }
        let epoch = daemon.store.connectionEpoch
        let current: @MainActor () -> Bool = { [weak daemon] in
            guard let daemon, registered(daemon), !daemon.policyBlock.isBlocked, case .connected = daemon.store.connectionState else {
                return false
            }
            return daemon.connection === connection && daemon.store.connectionEpoch == epoch
                && daemon.identity?.machineResourceID == machine && daemon.identity?.sessionResourceID == session
        }
        return (connection, machine, session, current)
    }

    /// Captures one daemon's connected machine/session owner and connection epoch.
    /// `registered` says whether the app still routes that machine to this daemon.
    public static func capture(_ daemon: DaemonService, registered: @escaping @MainActor (DaemonService) -> Bool) throws -> Self {
        let (connection, machine, session, current) = try connected(daemon, registered: registered)
        guard daemon.identity?.capabilities.contains("agent-cli-update-job-resolve-v1") == true else {
            throw DaemonError.missingCapabilities(["agent-cli-update-job-resolve-v1"])
        }
        let sideEvents = daemon.store.sideEvents
        guard let stamp = sideEvents.controlStamp, stamp.sourceID == connection.eventSourceID else { throw DaemonError.notConnected }
        var carrier: AgentCLIJobCarrier?
        // The owner-checked carrier, opened on first use: recovery and Resume start or observe
        // without an inventory read, and a route re-captured after a reconnect opens it to observe.
        let captured: @MainActor () async throws -> AgentCLIJobCarrier = {
            guard current() else { throw DaemonError.notConnected }
            if let carrier { return carrier }
            let jobs = try await connection.agentCLIJobs(expectedMachineID: machine, expectedSessionID: session)
            guard current() else { throw DaemonError.notConnected }
            carrier = jobs
            return jobs
        }
        return Self(machine: machine, session: session, isCurrent: current,
            inventory: { try await captured().inventory() },
            start: { cli, key in try await captured().startUpdate(cli: cli, idempotencyKey: key) },
            observe: { receipt in try await captured().observe(receipt) },
            resolve: { cli, key in try await captured().resolveUpdate(cli: cli, idempotencyKey: key) },
            changes: { AgentCLIUpdateActions.terminalChanges(sideEvents: sideEvents, stamp: stamp, current: current) })
    }
}
