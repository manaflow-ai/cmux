import Foundation

struct CloudRemoteOperationStep: Decodable, Sendable {
    public let id: String
    public let phase: CloudOperationPhase
    public let outcome: String
    let startedAtMs: Int64
    let endedAtMs: Int64?
}
