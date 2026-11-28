import CmuxNextDaemon
import CmuxNextRemote
import Foundation

/// Hosts the user entered that have not connected yet. The session registry
/// needs the remote session id, so such a host waits in the home daemon's
/// personal `ssh-hosts` projection (`SavedHostsStore`) and comes back at
/// launch. Once the registry holds the machine (after its first connect)
/// the entry is dropped: the registry is the only record from then on.
/// Only the home daemon stores it; entries hold transport fields, never a
/// secret.
extension SSHService {
    /// The store on the home daemon's current connection, or nil offline.
    private func savedHostsStore() -> SavedHostsStore? {
        guard let connection = machines.local.connection else { return nil }
        let id = ObjectIdentifier(connection)
        if let savedHosts, savedHosts.connection == id { return savedHosts.store }
        let store = SavedHostsStore(connection: connection)
        savedHosts = (id, store)
        return store
    }

    /// Records `session`'s host (or its new transport) before it connects.
    func rememberHost(_ session: SSHMachineSession) {
        let id = session.machineID, transport = Self.fields(Self.transport(session)) ?? [:]
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        writeSavedHosts("save") { $0.upsert(id: id, transport: transport, nowMs: now) }
    }

    /// Keeps a saved, never-connected host's `connect` flag in step.
    func updateSavedHost(_ session: SSHMachineSession) {
        let id = session.machineID, transport = Self.fields(Self.transport(session)) ?? [:]
        writeSavedHosts("update") { document in
            guard document.hosts.contains(where: { $0.id == id }) else { return }
            document.upsert(id: id, transport: transport, nowMs: 0)
        }
    }

    func forgetSavedHost(_ machineID: String) {
        writeSavedHosts("forget") { $0.remove(id: machineID) }
    }

    /// Adds saved hosts the registry does not hold and drops those it does.
    func restoreSavedHosts(registered records: [SessionRecord]) {
        guard machines.local.store.personal.isLoaded, let store = savedHostsStore() else { return }
        let registered = Set(records.compactMap { record in
            record.transport.flatMap(Self.fields).flatMap(SSHHost.init(transportFields:))?.machineID
        })
        // task-owner: one load and at most one CAS write of the saved hosts
        Task { [weak self] in
            do {
                let document = try await store.load()
                for host in document.pending(registered: registered) { self?.restore(host.transport) }
                if document.hosts.contains(where: { registered.contains($0.id) }) {
                    try await store.update { _ = $0.pruned(registered: registered) }
                }
            } catch {
                self?.logger.error("saved hosts: load failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func writeSavedHosts(_ what: String, _ change: @escaping @Sendable (inout SavedHostsDocument) -> Void) {
        guard let store = savedHostsStore() else { return }
        // task-owner: one CAS write (bounded retries inside the store)
        Task { [weak self] in
            do {
                try await store.load()
                try await store.update(change)
            } catch {
                self?.logger.error("saved hosts: \(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
