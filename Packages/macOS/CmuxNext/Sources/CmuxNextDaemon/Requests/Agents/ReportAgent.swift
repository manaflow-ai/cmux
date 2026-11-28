import Foundation

extension ReportAgentRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var state: AgentState
    }
}
