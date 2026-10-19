import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation

extension AgentCLIUpdateActions {
    convenience init(services: AppServices) {
        self.init { [weak services] invocation in
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
            guard services.machines.daemon(machine: daemon.machineID) === daemon,
                  !daemon.policyBlock.isBlocked, case .connected = daemon.store.connectionState,
                  let connection = daemon.connection, let identity = daemon.identity,
                  let machine = identity.machineResourceID, let session = identity.sessionResourceID else {
                throw DaemonError.notConnected
            }
            let epoch = daemon.store.connectionEpoch
            let current: @MainActor () -> Bool = { [weak services, weak daemon] in
                guard let services, let daemon else { return false }
                guard services.machines.daemon(machine: daemon.machineID) === daemon,
                      !daemon.policyBlock.isBlocked, case .connected = daemon.store.connectionState else { return false }
                return daemon.connection === connection && daemon.store.connectionEpoch == epoch
                    && daemon.identity?.machineResourceID == machine && daemon.identity?.sessionResourceID == session
            }
            var carrier: AgentCLIJobCarrier?
            return Route(machine: machine, session: session, isCurrent: current, inventory: {
                guard current() else { throw DaemonError.notConnected }
                let captured = try await connection.agentCLIJobs(expectedMachineID: machine, expectedSessionID: session)
                guard current() else { throw DaemonError.notConnected }
                carrier = captured
                return try await captured.inventory()
            }, start: { cli, key in
                guard current(), let carrier else { throw DaemonError.notConnected }
                return try await carrier.startUpdate(cli: cli, idempotencyKey: key)
            }, observe: { receipt in
                guard current(), let carrier else { throw DaemonError.notConnected }
                return try await carrier.observe(receipt)
            })
        }
    }
}
