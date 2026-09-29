public import CmuxNextSettings

/// `debug.hangs` and `debug.queue`: answered off the main actor (they read
/// lock-protected counters), so they work while the main thread is stalled.
extension ControlRouter {
    func diagnosticMethods() -> [ControlMethod] {
        [
            .snapshot("debug.hangs") { [weak self] call in
                guard let self else { throw Self.stopped }
                guard let watchdog = self.watchdog else {
                    return ["installed": false, "count": 0, "records": []]
                }
                let after = call.params["after"]?.intValue.map { UInt64(max(0, $0)) } ?? 0
                let limit = call.params["limit"]?.intValue ?? watchdog.log.capacity
                let summary = watchdog.log.summary
                let records = watchdog.log.records(after: after).suffix(max(0, limit))
                if call.params["clear"]?.boolValue == true { watchdog.log.clear() }
                return [
                    "installed": .bool(watchdog.isRunning),
                    "threshold_ms": .number(watchdog.configuration.threshold.fractionalMilliseconds),
                    "count": JSONValue(summary.count),
                    "max_ms": .number(summary.maxDuration.fractionalMilliseconds),
                    "total_ms": .number(summary.totalDuration.fractionalMilliseconds),
                    "records": .array(records.map(\.json)),
                ]
            },
            .snapshot("debug.queue") { [weak self] call in
                guard let self else { throw Self.stopped }
                var stats = self.workQueue.stats.json
                if case .object(var members) = stats {
                    members["max_pending"] = JSONValue(self.workQueue.limits.maxPending)
                    members["frame_budget_ms"] = .number(self.workQueue.limits.frameBudget.fractionalMilliseconds)
                    members["snapshot_generation"] = JSONValue(Int(truncatingIfNeeded: call.snapshot.generation))
                    stats = .object(members)
                }
                if call.params["reset"]?.boolValue == true { self.workQueue.resetStats() }
                return stats
            },
        ]
    }
}
