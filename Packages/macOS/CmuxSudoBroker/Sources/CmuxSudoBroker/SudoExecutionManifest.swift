import Foundation

struct SudoExecutionManifest: Codable, Sendable, Equatable {
    let id: String
    let currentDirectory: String
    let deadline: Date
}
