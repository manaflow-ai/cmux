import Foundation

struct TerminalWorkspaceBackendIdentity: Codable, Equatable, Sendable {
    var teamID: String
    var taskID: String
    var taskRunID: String
    var workspaceName: String
    var descriptor: String
}

struct TerminalWorkspaceBackendMetadata: Codable, Equatable, Sendable {
    var preview: String?
}
