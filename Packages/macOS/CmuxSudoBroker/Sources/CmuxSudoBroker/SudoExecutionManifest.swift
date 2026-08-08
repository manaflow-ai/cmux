import Foundation

struct SudoExecutionManifest: Codable, Sendable, Equatable {
    let id: String
    let requesterIdentity: SudoProcessIdentity
    let currentDirectory: String
    let deadline: Date
}
