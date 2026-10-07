/// The workloads of a run.
public enum BenchWorkload: String, Sendable, CaseIterable, Codable {
    case coldConnect = "connect"
    case rttIdle = "rtt"
    case rttUnderBulk = "rtt-bulk"
    case terminalFlood = "flood"
    case bulkFile = "bulk"
    case rawTransport = "raw"
    case reconnect = "reconnect"
    case roam = "roam"
}
