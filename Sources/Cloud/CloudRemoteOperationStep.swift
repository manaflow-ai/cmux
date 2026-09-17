import Foundation

struct CloudRemoteOperationStep: Decodable, Sendable {
    let id: String
    let phase: CloudOperationPhase
    let outcome: String
    let startedAtMs: Int64
    let endedAtMs: Int64?
}
