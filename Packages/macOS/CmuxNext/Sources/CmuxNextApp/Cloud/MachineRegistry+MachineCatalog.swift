import CmuxNextDaemon
import CmuxNextApps

extension MachineRegistry {
    /// Captures the exact local publication lease and admitted remote metadata.
    func catalogSource() -> MachineCatalogSource? {
        guard let owner = local.identity?.machineResourceID, let connection = local.connection,
              !local.policyBlock.isBlocked, case .connected = local.store.connectionState else { return nil }
        return MachineCatalogSource(owner: owner, writer: connection, epoch: local.store.connectionEpoch, machines: catalogRecords())
    }

    /// Existing carriers only; the handler rechecks this snapshot after each read.
    func agentInventoryRoutes() -> [AgentInventoryRoute] {
        daemons.map { daemon in
            AgentInventoryRoute(machineID: daemon.identity?.machineResourceID, reader: daemon.connection,
                                allowed: !daemon.policyBlock.isBlocked && self.daemon(machine: daemon.machineID) === daemon,
                                isDefault: daemon.isLocal)
        }
    }

    /// Read-only projection of admitted routes; evaluating it never starts a connection.
    func catalogRecords() -> [MachineCatalogRecord] {
        remoteDaemons.compactMap { daemon -> MachineCatalogRecord? in
            // Read policy and carrier state even while blocked, so readmission remains observable.
            let admitted = self.daemon(machine: daemon.machineID) === daemon
            guard let identity = daemon.identity, let id = identity.machineResourceID else { return nil }
            let origin: MachineCatalogRecord.Origin = session(daemon.machineID) != nil ? .cloud : sshSession(daemon.machineID) != nil ? .ssh : .server
            let ready: Bool = if case .connected = daemon.store.connectionState { daemon.connection != nil } else { false }
            guard admitted, !daemon.policyBlock.isBlocked else { return nil }
            return MachineCatalogRecord(id: id, name: machineName(daemon.machineID) ?? id.rawValue,
                                        origin: origin, status: ready ? .running : .unavailable,
                                        platform: identity.machinePlatform, capabilities: identity.machineCapabilities)
        }
    }
}
