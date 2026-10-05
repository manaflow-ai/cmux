import CmuxExtensionKit
import Foundation

/// Bounded native inventory consumed by the registered local organization engine.
struct SidebarOrganizationInput: Codable, Equatable, Sendable {
    struct Session: Codable, Equatable, Sendable {
        let toolId: String
        let sessionId: String
        let directory: String?
        let title: String
        var context: Context?
        var surfaceId: String? = nil
        var processGeneration: UInt64? = nil
    }
    struct Context: Codable, Equatable, Sendable {
        struct Message: Codable, Equatable, Sendable {
            let role: String
            let text: String
        }
        let recentMessages: [Message]
    }
    struct Workspace: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let revision: UInt64
        let groupId: String?
        let tags: [CmuxSidebarContextTag]
        let aliases: [String]
        let summary: String?
        let rejectedAutomaticTagIDs: [String]
        let rejectedSourceFingerprints: [String]
        var sessions: [Session]
    }
    let schemaVersion = 1
    let id: UUID
    let windowID: UUID?
    let createdAt: Date
    var workspaces: [Workspace]

    var metadata: Self {
        var result = self
        for workspace in result.workspaces.indices {
            for session in result.workspaces[workspace].sessions.indices { result.workspaces[workspace].sessions[session].context = nil }
        }
        return result
    }

    var isValid: Bool {
        !workspaces.isEmpty && workspaces.count <= 256
            && Set(workspaces.map(\.id)).count == workspaces.count
            && workspaces.allSatisfy { UUID(uuidString: $0.id) != nil && $0.title.count <= 512 && $0.sessions.count <= 64 }
    }
}
