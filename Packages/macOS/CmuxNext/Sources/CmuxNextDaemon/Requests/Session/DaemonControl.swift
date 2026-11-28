import Foundation

public struct ShutdownDaemonRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var accepted: Bool?
        public var pid: Int32?
        public var generation: DaemonGeneration?
        /// Terminals ended before the handoff (`end_terminals`).
        public var endedTerminals: UInt64?

        enum CodingKeys: String, CodingKey {
            case accepted, pid, generation
            case endedTerminals = "ended_terminals"
        }
    }
    public static let command = "shutdown-daemon"
    public var pid: Int32
    public var generation: DaemonGeneration
    public var force: Bool?
    /// Ends every terminal and waits for its host before the handoff
    /// (`terminal-reap-v1`). Test teardown uses it so no PTY outlives a run.
    public var endTerminals: Bool?
    /// With `endTerminals`, placed terminals keep their tabs, dead, for the
    /// next owner (`end-terminals-keep-layout-v1`).
    public var keepLayout: Bool?
    public init(pid: Int32, generation: DaemonGeneration, force: Bool? = nil, endTerminals: Bool? = nil, keepLayout: Bool? = nil) {
        self.pid = pid
        self.generation = generation
        self.force = force
        self.endTerminals = endTerminals
        self.keepLayout = keepLayout
    }
}

/// Keeps daemon replay colors in step with the app's Ghostty theme.
public struct SetDefaultColorsRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-default-colors"
    public var fg: String?
    public var bg: String?
    public var cursor: String?
    public init(fg: String? = nil, bg: String? = nil, cursor: String? = nil) {
        self.fg = fg
        self.bg = bg
        self.cursor = cursor
    }
}
