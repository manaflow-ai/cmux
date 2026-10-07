/// One run of the bench against one rig, written as JSON.
public struct BenchReport: Codable, Sendable {
    public var schema = "cmux-link-bench/1"
    public var rig: String
    public var carrier: String
    public var conditions: BenchConditions
    public var machine: MachineInfo
    public var startedAt: String
    public var durationSeconds: Double = 0
    public var coldConnect: ColdConnectResult?
    public var rttIdle: Distribution?
    public var rttUnderBulk: RTTUnderBulkResult?
    public var terminalFlood: ThroughputResult?
    public var bulkFile: ThroughputResult?
    public var rawTransport: ThroughputResult?
    public var reconnect: RecoveryResult?
    public var roam: RecoveryResult?
    public var memory: MemoryResult?
    public var errors: [String] = []
}
