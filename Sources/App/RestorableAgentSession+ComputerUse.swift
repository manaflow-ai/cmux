/// Computer-use projections over the shared restorable-agent session index.
extension RestorableAgentSessionIndex {
    func liveEntries() -> [(panelKey: PanelKey, entry: Entry)] {
        forkValidationEntries()
            .filter { _, entry in
                let processIDs = entry.agentProcessIDs.isEmpty ? entry.processIDs : entry.agentProcessIDs
                return !processIDs.isEmpty
            }
            .map { (panelKey: $0.0, entry: $0.1) }
    }
}
