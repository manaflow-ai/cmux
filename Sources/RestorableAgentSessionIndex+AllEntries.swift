import Foundation

extension RestorableAgentSessionIndex {
    /// Every recorded entry with its recorded (workspaceId, panel/surface
    /// UUID) key. Agents survive app relaunches and keep reporting their
    /// previous run's UUIDs through hooks, so callers that need
    /// current-workspace attribution must correlate by live pid
    /// (`Entry.processIDs`) in addition to the recorded workspace id.
    func allEntries() -> [(key: PanelKey, entry: Entry)] {
        entriesByPanel.map { ($0.key, $0.value) }
    }

}
