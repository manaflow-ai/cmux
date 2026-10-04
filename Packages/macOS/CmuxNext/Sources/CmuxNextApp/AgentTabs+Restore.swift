import CmuxNextDaemon

/// Agent tabs across quit and relaunch (R138): what the window document records for each pane,
/// and reopening those tabs on their acpmux sessions.
extension AgentTabStore {
    /// What the window document records for `paneKey`: each tab and its session.
    func records(in paneKey: String) -> [AgentTabRecord] {
        tabIDs(in: paneKey).map { AgentTabRecord(id: $0, session: sessions[$0]) }
    }

    /// Reopens recorded tabs in `paneKey` with their ids and sessions, without views until shown.
    /// A tab without a session (an empty new chat) or one already open is skipped.
    func restore(_ records: [AgentTabRecord], in paneKey: String, of store: DaemonStore) {
        let open = Set(tabsByPane.values.joined())
        let keys = records.compactMap { record -> String? in
            guard let session = record.session, record.id.hasPrefix(LocalAgentTab.prefix), !open.contains(record.id) else {
                return nil
            }
            sessions[record.id] = session
            return record.id
        }
        guard !keys.isEmpty else { return }
        tabsByPane[paneKey, default: []].append(contentsOf: keys)
        paneStores[paneKey] = store
        watch(store)
    }

    func reportChangedPanes(from old: [String: [String]]) {
        guard let onRecordsChanged else { return }
        for pane in Set(old.keys).union(tabsByPane.keys) where old[pane] != tabsByPane[pane] {
            onRecordsChanged(pane, records(in: pane))
        }
    }
}
