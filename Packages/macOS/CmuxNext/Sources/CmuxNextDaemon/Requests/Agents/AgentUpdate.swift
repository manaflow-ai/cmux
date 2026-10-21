import Foundation

/// `agent-update-plan {}`: the machine's agent CLIs that are outdated and that its acpmux can
/// update without sudo, and its threads (Update Everything's confirmation).
public struct AgentUpdatePlanRequest: DaemonRequest {
    public struct Harness: Decodable, Sendable, Equatable {
        public var id: String
        /// The harness's display name, when its profile has one.
        public var name: String?
        public var version: String?
        public var latest: String?
    }

    public struct Response: Decodable, Sendable, Equatable {
        public var harnesses: [Harness]
        /// Threads with a running agent.
        public var liveThreads: Int
        /// Threads in a turn now.
        public var runningThreads: Int

        enum CodingKeys: String, CodingKey {
            case harnesses
            case liveThreads = "live_threads"
            case runningThreads = "running_threads"
        }
    }

    public static let command = "agent-update-plan"
    /// The capability of a daemon that updates its machine's agent CLIs (`agent-update-v1`,
    /// cmux-tui/spec/commands.md agent-update-plan / agent-update-apply): it asks the machine's own
    /// acpmux, so Update Everything reaches this Mac, SSH and Cloud machines the same way.
    public static let capability = "agent-update-v1"
    public static var requiredCapability: String? { capability }
    public init() {}
}

/// `agent-update-apply {ids, continue_threads}`: runs the acpmux's own update of each named
/// harness that is still outdated and waits for them; with `continue_threads`, then restarts each
/// live thread on its harness's new version, resuming its conversation (a thread in a turn
/// restarts when the turn ends). No command travels: the machine builds every update itself.
public struct AgentUpdateApplyRequest: DaemonRequest {
    public struct Result: Decodable, Sendable, Equatable {
        public var id: String
        public var ok: Bool
        /// The version after the update.
        public var version: String?
        /// Why it failed (the updater's last output line).
        public var error: String?
    }

    public struct Response: Decodable, Sendable, Equatable {
        public var results: [Result]
        /// Threads restarted now (they were idle).
        public var threadsRestarted: Int
        /// Threads that restart when their running turn ends.
        public var threadsAfterTurn: Int
        /// Threads that could not restart and still run the old agent (nil from an older daemon).
        public var threadsFailed: Int?
        /// Why threads could not restart: the restart call's error, or the first thread's.
        public var threadsError: String?

        enum CodingKeys: String, CodingKey {
            case results
            case threadsRestarted = "threads_restarted"
            case threadsAfterTurn = "threads_after_turn"
            case threadsFailed = "threads_failed"
            case threadsError = "threads_error"
        }
    }

    public static let command = "agent-update-apply"
    public static var requiredCapability: String? { AgentUpdatePlanRequest.capability }
    /// The longest an apply may take: each updater may run 15 minutes (acpmux `probe.rs`).
    public static let timeout: Duration = .seconds(30 * 60)

    public var ids: [String]
    public var continueThreads: Bool

    public init(ids: [String], continueThreads: Bool) {
        self.ids = ids
        self.continueThreads = continueThreads
    }

    enum CodingKeys: String, CodingKey {
        case ids
        case continueThreads = "continue_threads"
    }
}
