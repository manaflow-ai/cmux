import Foundation

/// The Task Manager's rows from two samples: one row per live process, each
/// counted once. CPU follows ``ResourceAggregator/share(_:since:)``.
///
/// Order: the app, the daemons and the shared Chromium processes first (by
/// kind), then tab processes in tab order. A process several tabs use (one
/// Chromium renderer for two tabs of a site) is one row naming every tab.
public struct TaskManagerSnapshot: Sendable, Equatable {
    public var rows: [TaskManagerRow]
    /// The sum over the rows; CPU is nil until a second sample.
    public var total: ResourceUsage
    /// The items Memory Saver discarded, with the memory each saved (``TaskManagerModel`` fills it
    /// while `taskManagerMemorySaved` is on; empty otherwise).
    public private(set) var discarded: [TaskManagerDiscardedItem] = []
    /// What Memory Saver freed: the sum of the known `savedBytes` of `discarded`.
    public private(set) var freedBytes: UInt64 = 0

    public init(rows: [TaskManagerRow] = [], total: ResourceUsage = .zero) {
        self.rows = rows
        self.total = total
    }

    /// Lists `items` as the discarded items and sums what they saved.
    public mutating func setDiscarded(_ items: [TaskManagerDiscardedItem]) {
        discarded = items
        freedBytes = items.reduce(0) { $0 &+ ($1.savedBytes ?? 0) }
    }

    public static let empty = TaskManagerSnapshot()

    public init(current: TaskManagerSampleSet, previous: TaskManagerSampleSet?) {
        let samples = current.resources.samples
        let before = previous?.resources.samples
        var order: [ProcessKey] = []
        var kinds: [ProcessKey: TaskManagerRowKind] = [:]
        var titles: [ProcessKey: [String]] = [:]
        var tabs: [ProcessKey: [String]] = [:]
        func note(_ key: ProcessKey, _ kind: TaskManagerRowKind) {
            guard samples[key] != nil else { return }
            if kinds[key] == nil { order.append(key) }
            // A process first named shared (the app, a GPU) keeps that kind.
            if kinds[key].map({ $0 > kind }) ?? true { kinds[key] = kind }
        }
        for shared in current.resources.shared { note(shared.key, TaskManagerRowKind(shared.role)) }
        for daemon in current.daemons { note(daemon, .daemon) }
        for tab in current.resources.tabs {
            for key in tab.processes {
                note(key, TaskManagerRowKind(tab.kind))
                guard samples[key] != nil, !(tabs[key] ?? []).contains(tab.tabID) else { continue }
                tabs[key, default: []].append(tab.tabID)
                titles[key, default: []].append(tab.title.isEmpty ? Strings.untitled : tab.title)
            }
        }
        var rows: [TaskManagerRow] = []
        var memory: UInt64 = 0
        var cpu: Double = 0
        for key in order {
            guard let sample = samples[key], let kind = kinds[key] else { continue }
            let share = before?[key].map { ResourceAggregator.share(sample, since: $0) }
            let owned = kind >= .terminal
            let name = sample.name.isEmpty ? Strings.untitled : sample.name
            rows.append(TaskManagerRow(
                id: key, kind: kind,
                task: owned ? (titles[key] ?? []).joined(separator: Strings.listSeparator) : kind.title,
                name: name, cpu: previous == nil ? nil : (share ?? 0), memoryBytes: sample.memoryBytes,
                tabIDs: owned ? tabs[key] ?? [] : []
            ))
            memory &+= sample.memoryBytes
            cpu += share ?? 0
        }
        let ranked = rows.enumerated().sorted { lhs, rhs in
            let l = lhs.element.kind >= .terminal ? TaskManagerRowKind.terminal : lhs.element.kind
            let r = rhs.element.kind >= .terminal ? TaskManagerRowKind.terminal : rhs.element.kind
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
        self.init(rows: ranked, total: ResourceUsage(cpu: previous == nil ? nil : cpu, memoryBytes: memory))
    }

    /// The row of `key`, if it is listed.
    public func row(_ key: ProcessKey) -> TaskManagerRow? {
        rows.first { $0.id == key }
    }
}
