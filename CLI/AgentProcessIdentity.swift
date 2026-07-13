import Foundation

/// The minimal immutable process identity needed for agent ancestry checks.
struct AgentProcessIdentity: Sendable, Equatable {
    var pid: Int
    var parentPID: Int
    var startedAt: TimeInterval
    var executableName: String?
    var arguments: [String]
}
