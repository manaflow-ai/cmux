import Foundation

extension ResourceSampleSet {
    /// Each available tab's estimated memory in this sample, by tab id: its own processes' footprint
    /// (a process several tabs list split evenly between them) plus its app-side estimate. A shared
    /// process (the app, GPU, network) is never a tab's, even when the tab also lists it, the same
    /// rule as ``ResourceAggregator/report(current:previous:)``. A tab whose numbers are unavailable
    /// is left out; an available tab with nothing measured is listed with 0.
    ///
    /// The one estimate behind the hibernation ranking and the memory a discarded item saved.
    /// Chrome estimates a page the same way: `PageNodeImpl::EstimatePrivateFootprintSize`
    /// (components/performance_manager/graph/page_node_impl.cc) sums its frames' shares of their
    /// process's private footprint.
    ///
    /// - Parameter kinds: The kinds of tab to list; nil lists every kind.
    public func tabMemory(kinds: Set<TabResourceKind>? = nil) -> [String: UInt64] {
        let sharedKeys = Set(shared.map(\.key))
        let owned = tabs.map { Set($0.processes).subtracting(sharedKeys) }
        var sharers: [ProcessKey: UInt64] = [:]
        for keys in owned { for key in keys { sharers[key, default: 0] += 1 } }
        var bytes: [String: UInt64] = [:]
        for (tab, keys) in zip(tabs, owned) where tab.available && kinds.map({ $0.contains(tab.kind) }) ?? true {
            let own = keys.reduce(UInt64(0)) { total, key in
                guard let memory = samples[key]?.memoryBytes else { return total }
                return total &+ memory / max(sharers[key] ?? 1, 1)
            }
            bytes[tab.tabID] = own &+ tab.estimatedAppBytes
        }
        return bytes
    }
}

extension TabResourceKind {
    /// The kinds of tab that show a web page (the browser hibernation's tabs).
    public static let browserPages: Set<TabResourceKind> = [.chromium, .webkit]
}
