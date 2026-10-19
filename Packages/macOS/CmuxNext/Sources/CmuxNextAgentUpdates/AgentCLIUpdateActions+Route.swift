import CmuxNextActions
import CmuxNextDaemon
public import CmuxNextDaemonService

extension AgentCLIUpdateActions {
    /// The app's daemons, read when an update captures its owner.
    public struct Daemons {
        let active: @MainActor () -> DaemonService?
        let machine: @MainActor (String) -> DaemonService?

        public init(active: @escaping @MainActor () -> DaemonService?, machine: @escaping @MainActor (String) -> DaemonService?) {
            self.active = active
            self.machine = machine
        }
    }

    /// The palette's target machine, else the active daemon, while the app still routes to it.
    public convenience init(daemons: Daemons, unsupported: @escaping @MainActor () -> String,
                            nothingToUpdate: @escaping @MainActor () -> String,
                            stillUpdating: @escaping @MainActor (String) -> String, localMachine: String) {
        self.init(capture: { invocation in
            let registered: @MainActor (DaemonService) -> Bool = { daemons.machine($0.machineID) === $0 }
            if let target = invocation.target {
                guard target.kind == .machine, let daemon = daemons.machine(target.id) else { throw DaemonError.notConnected }
                return try Route.capture(daemon, registered: registered)
            }
            guard let daemon = daemons.active() else { throw DaemonError.notConnected }
            return try Route.capture(daemon, registered: registered)
        }, unsupported: unsupported, nothingToUpdate: nothingToUpdate, stillUpdating: stillUpdating, localMachine: localMachine)
    }
}

extension AgentCLIUpdateActions.Route {
    /// Captures one daemon's connected machine/session owner and connection epoch.
    /// `registered` says whether the app still routes that machine to this daemon.
    public static func capture(_ daemon: DaemonService, registered: @escaping @MainActor (DaemonService) -> Bool) throws -> Self {
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
        var carrier: AgentCLIJobCarrier?
        // The owner-checked carrier; a route re-captured after a reconnect opens it to observe receipts.
        let opened: @MainActor () async throws -> AgentCLIJobCarrier = {
            guard current() else { throw DaemonError.notConnected }
            if let carrier { return carrier }
            let captured = try await connection.agentCLIJobs(expectedMachineID: machine, expectedSessionID: session)
            guard current() else { throw DaemonError.notConnected }
            carrier = captured
            return captured
        }
        return Self(machine: machine, session: session, isCurrent: current, inventory: {
            try await opened().inventory()
        }, start: { cli, key in
            // A start always follows this route's inventory read, which opened the carrier.
            guard current(), let carrier else { throw DaemonError.notConnected }
            return try await carrier.startUpdate(cli: cli, idempotencyKey: key)
        }, observe: { receipt in
            try await opened().observe(receipt)
        })
    }
}
