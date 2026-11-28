import Foundation

extension ShutdownDaemonRequest {
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
}
