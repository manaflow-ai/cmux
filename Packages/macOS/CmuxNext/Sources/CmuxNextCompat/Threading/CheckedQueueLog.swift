#if DEBUG || CMUX_BENCH_HOOKS
public import Dispatch
internal import os

/// The queues one call site made through `DispatchQueue.checked` for one row (or one undeclared label).
public struct CheckedQueueRecord: Sendable, Equatable {
    /// The label of the first queue made here.
    public var label: String
    /// The name of the registry row the label matches; nil when no row declares it.
    public var declaredAs: String?
    /// The QoS the queue runs at: the one it states, else its target's.
    public var qos: ThreadQoS
    /// The label of the queue it targets; nil with no target.
    public var target: String?
    /// The calling code's `fileID:line`.
    public var site: String
    /// What is wrong with the queue (see `ThreadRegistry.problem`); nil when it matches its row.
    public var problem: String?
    /// How many queues this site made for this row.
    public var count: Int
}

/// Every queue `DispatchQueue.checked` made in this process, one record per call site and row, which
/// `debug.threads` lists under `queues` (Debug and bench builds). A queue made per child process
/// (`com.cmuxterm.next.daemon.exit.<pid>`) adds to its site's count, not a record.
public final class CheckedQueueLog: Sendable {
    /// The app process's log, which `DispatchQueue.checked` writes.
    public static let app = CheckedQueueLog()

    /// The most records the log keeps; a site past it (an undeclared interpolated label) adds to ``droppedCount``.
    static let recordLimit = 512

    private struct Key: Hashable, Sendable {
        var site: String
        var name: String
    }

    private struct State: Sendable {
        var order: [Key] = []
        var records: [Key: CheckedQueueRecord] = [:]
        var dropped = 0
    }

    // Written once per queue creation, never on a per-frame or per-key path; a main-thread wait over 2 ms is
    // recorded (CmuxNextCompat Mutex, threading-model.md "Donating waits").
    private let state = Mutex(State())

    /// Makes an empty log (tests; the app uses ``app``).
    public init() {}

    /// The records, in the order their first queue was made.
    public var records: [CheckedQueueRecord] {
        state.withLock { state in state.order.compactMap { state.records[$0] } }
    }

    /// How many queues were not recorded because the log was full.
    public var droppedCount: Int {
        state.withLock { $0.dropped }
    }

    /// Records a new queue, and logs a fault naming `site` when it does not match its row.
    ///
    /// - Parameters:
    ///   - label: The queue's label.
    ///   - qos: The QoS it states; unspecified when it runs at its target's.
    ///   - target: The queue it targets.
    ///   - site: The calling code's `fileID:line`.
    ///   - registry: The rows it is checked against.
    /// - Returns: The site's record, this queue counted.
    @discardableResult
    func record(label: String, qos: ThreadQoS, target: DispatchQueue?, site: String, registry: ThreadRegistry) -> CheckedQueueRecord {
        let targetQoS = target.map { ThreadQoS($0.qos.qosClass) }
        let declaredAs = registry.declaration(for: label)?.name
        let made = CheckedQueueRecord(label: label, declaredAs: declaredAs, qos: ThreadRegistry.effectiveQoS(qos, targetQoS: targetQoS),
                                      target: target?.label, site: site,
                                      problem: registry.problem(label: label, qos: qos, targetQoS: targetQoS), count: 1)
        if let problem = made.problem {
            Logger(subsystem: "com.cmuxterm.app.next", category: "threads").fault("\(site, privacy: .public): \(problem, privacy: .public)")
        }
        let key = Key(site: site, name: declaredAs ?? label)
        return state.withLock { state -> CheckedQueueRecord in
            if var existing = state.records[key] {
                existing.count += 1
                state.records[key] = existing
                return existing
            }
            guard state.order.count < Self.recordLimit else {
                state.dropped += 1
                return made
            }
            state.order.append(key)
            state.records[key] = made
            return made
        }
    }
}
#endif
