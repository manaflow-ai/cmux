import CmuxNextDaemon

extension MachineRegistry {
    /// Read-only projection of admitted routes; evaluating it never starts a connection.
    func catalogRecords() -> [MachineCatalogRecord] {
        remoteDaemons.compactMap { daemon -> MachineCatalogRecord? in
            guard !daemon.policyBlock.isBlocked, self.daemon(machine: daemon.machineID) === daemon,
                  let identity = daemon.identity, let id = identity.machineResourceID else { return nil }
            let origin: MachineCatalogRecord.Origin = session(daemon.machineID) != nil ? .cloud : sshSession(daemon.machineID) != nil ? .ssh : .server
            let ready: Bool = if case .connected = daemon.store.connectionState { daemon.connection != nil } else { false }
            return MachineCatalogRecord(id: id, name: machineName(daemon.machineID) ?? id.rawValue,
                                        origin: origin, status: ready ? .running : .unavailable,
                                        platform: identity.machinePlatform, capabilities: identity.machineCapabilities)
        }
    }
}
