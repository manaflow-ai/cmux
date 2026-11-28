import Foundation

/// One tab's numbers in a report.
public struct TabResourceReport: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var kind: TabResourceKind
    public var usage: ResourceUsage
    /// Live processes counted for this tab.
    public var processCount: Int
    /// Other tabs in the report that share at least one of its processes.
    public var sharedWithTabs: Int
    public var available: Bool

    public init(id: String, title: String, kind: TabResourceKind, usage: ResourceUsage,
                processCount: Int, sharedWithTabs: Int, available: Bool) {
        self.id = id
        self.title = title
        self.kind = kind
        self.usage = usage
        self.processCount = processCount
        self.sharedWithTabs = sharedWithTabs
        self.available = available
    }
}

/// A target's numbers: each tab, the deduplicated total over the tabs, and
/// the shared processes on their own line.
public struct ResourceReport: Sendable, Equatable {
    public var tabs: [TabResourceReport]
    /// Every tab process counted once, plus app-side estimates. Shared
    /// processes are not in it.
    public var total: ResourceUsage
    public var shared: ResourceUsage
    /// The roles present in `shared`, in display order.
    public var sharedRoles: [SharedRole]
    /// Distinct live processes behind `total`.
    public var processCount: Int

    public init(tabs: [TabResourceReport] = [], total: ResourceUsage = .zero, shared: ResourceUsage = .zero,
                sharedRoles: [SharedRole] = [], processCount: Int = 0) {
        self.tabs = tabs
        self.total = total
        self.shared = shared
        self.sharedRoles = sharedRoles
        self.processCount = processCount
    }

    public static let empty = ResourceReport()

    /// The per-tab rows under a workspace's total: its heaviest tabs, or none
    /// for a lone tab, whose numbers are the total.
    public func breakdown(_ limit: Int) -> [TabResourceReport] {
        tabs.count > 1 ? topConsumers(limit) : []
    }

    /// The heaviest tabs first: CPU (to 0.1%), then memory, then input order.
    public func topConsumers(_ limit: Int) -> [TabResourceReport] {
        let ranked = tabs.enumerated().filter(\.element.available).sorted { lhs, rhs in
            let l = ((lhs.element.usage.cpu ?? 0) * 1000).rounded()
            let r = ((rhs.element.usage.cpu ?? 0) * 1000).rounded()
            if l != r { return l > r }
            if lhs.element.usage.memoryBytes != rhs.element.usage.memoryBytes {
                return lhs.element.usage.memoryBytes > rhs.element.usage.memoryBytes
            }
            return lhs.offset < rhs.offset
        }
        return ranked.prefix(max(limit, 0)).map(\.element)
    }
}

/// Turns two sample sets into a report. Pure: the tests drive it with
/// synthetic samples.
///
/// Rules:
/// - A process counts once per total, however many tabs list it.
/// - A shared process (GPU, network, the app) never counts for a tab or in
///   the total, even when a tab also lists it; it is on the shared line.
/// - CPU is (cpu time delta) / (wall time delta) per process between the
///   previous and the current sample of that process. A process with no
///   previous sample (new, or the first sample) adds no CPU; the whole CPU
///   value is nil when there is no previous sample set.
public struct ResourceAggregator {
    public init() {}
    public static func report(current: ResourceSampleSet, previous: ResourceSampleSet?) -> ResourceReport {
        let sharedKeys = Set(current.shared.map(\.key))
        let previousSamples = previous?.samples
        var owners: [ProcessKey: Int] = [:]
        let tabKeys: [Set<ProcessKey>] = current.tabs.map { tab in
            Set(tab.processes).subtracting(sharedKeys).filter { current.samples[$0] != nil }
        }
        for keys in tabKeys {
            for key in keys { owners[key, default: 0] += 1 }
        }
        var tabs: [TabResourceReport] = []
        var union = Set<ProcessKey>()
        var estimates: UInt64 = 0
        for (index, tab) in current.tabs.enumerated() {
            let keys = tabKeys[index]
            union.formUnion(keys)
            estimates &+= tab.estimatedAppBytes
            var usage = self.usage(of: keys, current: current.samples, previous: previousSamples)
            usage.memoryBytes &+= tab.estimatedAppBytes
            let sharedWith = current.tabs.indices.filter { other in
                other != index && !tabKeys[other].isDisjoint(with: keys)
            }.count
            tabs.append(TabResourceReport(
                id: tab.tabID, title: tab.title, kind: tab.kind, usage: usage,
                processCount: keys.count, sharedWithTabs: sharedWith, available: tab.available
            ))
        }
        var total = usage(of: union, current: current.samples, previous: previousSamples)
        total.memoryBytes &+= estimates
        let liveShared = current.shared.filter { current.samples[$0.key] != nil }
        let shared = usage(of: Set(liveShared.map(\.key)), current: current.samples, previous: previousSamples)
        let roles = Array(Set(liveShared.map(\.role))).sorted()
        return ResourceReport(tabs: tabs, total: total, shared: shared, sharedRoles: roles, processCount: union.count)
    }

    /// Memory and CPU of `keys`, each process once.
    public static func usage(of keys: Set<ProcessKey>, current: [ProcessKey: ProcessSample],
                             previous: [ProcessKey: ProcessSample]?) -> ResourceUsage {
        var memory: UInt64 = 0
        var cpu: Double = 0
        for key in keys {
            guard let now = current[key] else { continue }
            memory &+= now.memoryBytes
            if let before = previous?[key] { cpu += share(now, since: before) }
        }
        return ResourceUsage(cpu: previous == nil ? nil : cpu, memoryBytes: memory)
    }

    /// CPU share of one core between two samples of one process; 0 when
    /// the clock did not advance or the counter went back (PID reuse).
    public static func share(_ now: ProcessSample, since before: ProcessSample) -> Double {
        guard now.sampledAtNanos > before.sampledAtNanos, now.cpuNanos >= before.cpuNanos else { return 0 }
        return Double(now.cpuNanos - before.cpuNanos) / Double(now.sampledAtNanos - before.sampledAtNanos)
    }
}
