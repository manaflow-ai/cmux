import Foundation

/// Records a hook's agent state for a PTY surface (`report-agent`). The
/// daemon keeps one record per surface; `list-agents` and the sidebar
/// activity read it back.
public struct ReportAgentRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var state: AgentState
    }
    public static let command = "report-agent"
    public var surface: SurfaceID
    public var state: AgentState
    /// `hook` or `socket` (the only sources raw report-agent accepts).
    public var source: String
    public var session: String?
    public init(surface: SurfaceID, state: AgentState, source: String = "hook", session: String? = nil) {
        self.surface = surface
        self.state = state
        self.source = source
        self.session = session
    }
}
