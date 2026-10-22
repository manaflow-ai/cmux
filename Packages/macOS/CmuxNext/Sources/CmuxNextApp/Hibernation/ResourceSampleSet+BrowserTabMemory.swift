import CmuxNextResources

extension ResourceSampleSet {
    /// Each browser tab's memory in this sample, for the hibernation ranking: its renderers'
    /// footprint (a renderer shared by several tabs split evenly between them) and its app-side
    /// estimate. Tabs whose numbers are unavailable are left out.
    func browserTabMemory() -> [String: UInt64] {
        let pages = tabs.filter { $0.kind == .chromium || $0.kind == .webkit }
        var sharers: [ProcessKey: UInt64] = [:]
        for tab in pages { for process in Set(tab.processes) { sharers[process, default: 0] += 1 } }
        var bytes: [String: UInt64] = [:]
        for tab in pages where tab.available {
            let own = Set(tab.processes).reduce(UInt64(0)) { total, process in
                guard let memory = samples[process]?.memoryBytes else { return total }
                return total + memory / max(sharers[process] ?? 1, 1)
            }
            bytes[tab.tabID] = own + tab.estimatedAppBytes
        }
        return bytes
    }
}
