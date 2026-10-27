#if DEBUG || CMUX_BLOCKING_CHECKS || CMUX_BENCH_HOOKS
internal import Dispatch

extension DispatchQueue {
    /// The class the queue's work runs at: its own, else the one `checked` noted for a queue made without one
    /// (its target's, through any number of checked targets); unspecified for a queue with neither, which runs
    /// at its submitters' class. `qos` alone reads unspecified for a queue that only targets a utility queue.
    var runningQoS: ThreadQoS {
        let stated = ThreadQoS(qos.qosClass)
        guard stated == .unspecified else { return stated }
        return getSpecific(key: RunningQoSKey.shared.key) ?? .unspecified
    }

    /// Notes on a queue made without a class the class its target runs at, which ``runningQoS`` reads
    /// (`checked` and `checkedSerial` call it on each queue they make).
    func noteRunningQoS(stated: DispatchQoS, target: DispatchQueue?) {
        guard stated.qosClass == .unspecified, let runs = target?.runningQoS, runs != .unspecified else { return }
        setSpecific(key: RunningQoSKey.shared.key, value: runs)
    }
}

/// The queue-specific key ``Dispatch/DispatchQueue/runningQoS`` reads and `checked` writes.
private struct RunningQoSKey: @unchecked Sendable { // crash-allow: DispatchSpecificKey stores nothing; dispatch uses only its address as the key, and set/getSpecific are thread-safe
    static let shared = RunningQoSKey()
    let key = DispatchSpecificKey<ThreadQoS>()
}
#endif
