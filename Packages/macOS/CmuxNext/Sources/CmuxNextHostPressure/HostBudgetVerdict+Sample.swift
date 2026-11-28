import Foundation

extension HostBudgetVerdict {
    /// A forced level's numbers (Debug Settings `hostPressure.force`, captures): an overloaded 12-core
    /// Mac (load 146) at critical, a busy-but-fine one at warning, with every gauge kind as
    /// cmux-host-budget `gauges.rs` words them. The host is a neutral name, not one of our own machines.
    public static func sample(critical: Bool) -> Self {
        var verdict = HostBudgetVerdict(host: "This Mac", cores: 12, load1: critical ? 146 : 9.6,
                                        pressure: critical ? .warn : .normal, availableRAMFraction: critical ? 0.04 : 0.31,
                                        swapMBPerMin: critical ? 410 : 0)
        verdict.localTurns = critical ? 39 : 14
        verdict.backgroundProcesses = critical ? 1298 : 212
        let top = critical
            ? #"[{"session_id":"s1","name":"app-efficiency","turns":9,"processes":410},{"session_id":"s2","name":"chief-fix","turns":7,"processes":302},{"session_id":"s3","name":"gui-push","turns":5,"processes":188}]"#
            : #"[{"session_id":"s1","name":"app-efficiency","turns":4,"processes":80},{"session_id":"s2","name":"chief-fix","turns":3,"processes":61}]"#
        verdict.top = try? JSONDecoder().decode([HostBudgetSession].self, from: Data(top.utf8))
        verdict.gauges = critical
            ? [HostPressureGauge(kind: "cpu", percent: 1216.7, level: "critical", detail: "load 146 / 12 P-cores"),
               HostPressureGauge(kind: "memory", percent: 46.2, level: "critical", detail: "stalled 46.2% of 10 s"),
               HostPressureGauge(kind: "tokens", percent: 63, level: "critical", detail: "stalled 63% of 10 s"),
               HostPressureGauge(kind: "cache", percent: 6.6, level: "normal", detail: "66 of 1000 calls missed"),
               HostPressureGauge(kind: "mac_slots", percent: 90, level: "warn", detail: "9 of 10 in use")]
            : [HostPressureGauge(kind: "cpu", percent: 80, level: "warn", detail: "load 9.6 / 12 P-cores"),
               HostPressureGauge(kind: "memory", percent: 12.4, level: "warn", detail: "stalled 12.4% of 10 s"),
               HostPressureGauge(kind: "tokens", percent: 4, level: "normal", detail: "stalled 4% of 10 s"),
               HostPressureGauge(kind: "cache", percent: 6.6, level: "normal", detail: "66 of 1000 calls missed"),
               HostPressureGauge(kind: "mac_slots", percent: 40, level: "normal", detail: "4 of 10 in use")]
        return verdict
    }
}
