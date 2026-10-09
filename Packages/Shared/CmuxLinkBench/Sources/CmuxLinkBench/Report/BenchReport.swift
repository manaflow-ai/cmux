import Foundation

/// One run of the bench against one rig, written as JSON.
public struct BenchReport: Codable, Sendable {
    public var schema = "cmux-link-bench/1"
    /// Build identity for app-captured reports. The standalone Mac runner may
    /// leave this nil because it is not embedded in an app bundle.
    public var provenance: BenchReportProvenance? = nil
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

/// Exact source/build identity for a persisted benchmark artifact.
public struct BenchReportProvenance: Codable, Sendable, Hashable, Equatable {
    public let sourceGitSHA: String
    public let devTag: String
    public let buildNumber: String
    public let runID: String

    public init(sourceGitSHA: String, devTag: String, buildNumber: String, runID: String = UUID().uuidString) {
        self.sourceGitSHA = sourceGitSHA
        self.devTag = devTag
        self.buildNumber = buildNumber
        self.runID = runID
    }

    private enum CodingKeys: String, CodingKey {
        case sourceGitSHA = "source_git_sha"
        case devTag = "dev_tag"
        case buildNumber = "build_number"
        case runID = "run_id"
    }
}
