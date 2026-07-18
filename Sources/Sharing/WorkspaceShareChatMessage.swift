import Foundation

struct WorkspaceShareChatMessage: Decodable, Equatable, Sendable {
    let id: String
    let userId: String
    let displayName: String
    let color: Int
    let text: String
    let createdAt: Int64
}
