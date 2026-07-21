import Foundation

struct WorkspaceShareRemotePointer: Decodable, Equatable, Sendable, Identifiable {
    struct Participant: Decodable, Equatable, Sendable {
        let connectionId: String
        let userId: String
        let displayName: String
        let color: Int
        let role: String
    }

    let participant: Participant
    let x: Double
    let y: Double
    let layoutRevision: UInt64
    let targetId: String?

    var id: String { participant.connectionId }
}

struct WorkspaceShareTextSelection: Decodable, Equatable, Sendable {
    let participant: WorkspaceShareRemotePointer.Participant
    let docId: String
    let anchorUTF16: Int
    let headUTF16: Int
}
