import Foundation

/// One tab's memory estimate in a sample (``ResourceSampleSet/tabMemoryReadings(kinds:)``).
public struct TabMemoryReading: Hashable, Sendable {
    /// Its share of its own processes' footprint plus its app-side estimate.
    public var bytes: UInt64
    /// The tabs that list at least one of its own processes, itself included. Its number is a share
    /// of those processes, so it moves when one of these tabs comes, goes or grows.
    public var sharers: Set<String>

    public init(bytes: UInt64, sharers: Set<String>) {
        self.bytes = bytes
        self.sharers = sharers
    }
}

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
        tabMemoryReadings(kinds: kinds).mapValues(\.bytes)
    }

    /// ``tabMemory(kinds:)`` with the tabs each number is shared with: every tab, of any kind, that
    /// lists one of the tab's own processes.
    ///
    /// - Parameter kinds: The kinds of tab to list; nil lists every kind.
    public func tabMemoryReadings(kinds: Set<TabResourceKind>? = nil) -> [String: TabMemoryReading] {
        let sharedKeys = Set(shared.map(\.key))
        let owned = tabs.map { Set($0.processes).subtracting(sharedKeys) }
        var sharers: [ProcessKey: Set<String>] = [:]
        for (tab, keys) in zip(tabs, owned) { for key in keys { sharers[key, default: []].insert(tab.tabID) } }
        var readings: [String: TabMemoryReading] = [:]
        for (tab, keys) in zip(tabs, owned) where tab.available && kinds.map({ $0.contains(tab.kind) }) ?? true {
            let own = keys.reduce(UInt64(0)) { total, key in
                guard let memory = samples[key]?.memoryBytes else { return total }
                return total &+ memory / UInt64(max(sharers[key]?.count ?? 1, 1))
            }
            let with = keys.reduce(into: Set([tab.tabID])) { $0.formUnion(sharers[$1] ?? []) }
            readings[tab.tabID] = TabMemoryReading(bytes: own &+ tab.estimatedAppBytes, sharers: with)
        }
        return readings
    }
}

extension TabResourceKind {
    /// The kinds of tab that show a web page (the browser hibernation's tabs).
    public static let browserPages: Set<TabResourceKind> = [.chromium, .webkit]
}
