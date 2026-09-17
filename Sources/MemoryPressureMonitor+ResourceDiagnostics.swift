import Foundation

extension MemoryPressureMonitor {
    /// Exposes the monitor's last applied sample without sampling or changing pressure.
    func resourceDiagnosticPayload() -> [String: Any] {
        let aggregate = aggregateMemoryPressure.map { snapshot -> [String: Any] in
            [
                "severity": snapshot.severity.logName,
                "source": snapshot.source.rawValue,
                "aggregate_bytes": snapshot.aggregateBytes as Any? ?? NSNull(),
                "physical_memory_bytes": snapshot.physicalMemoryBytes as Any? ?? NSNull(),
                "available_memory_bytes": snapshot.availableMemoryBytes as Any? ?? NSNull(),
                "process_count": snapshot.processCount,
                "process_count_available": snapshot.source != .coalition,
                "missing_process_count": snapshot.missingProcessCount,
                "actionable": snapshot.isActionable,
                "sampled_at": ISO8601DateFormatter().string(from: snapshot.sampledAt)
            ]
        }
        return [
            "system_severity": currentSeverity.logName,
            "aggregate": aggregate as Any? ?? NSNull()
        ]
    }
}
