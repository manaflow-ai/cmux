import CMUXMobileCore
import Foundation

/// A complete room snapshot; replacement remains correct if intermediate frames coalesce.
public struct WorkspacePresenceSnapshot: Codable, Equatable, Sendable {
    /// Versioned event discriminator.
    public let type: String
    /// Wire protocol version.
    public let version: Int
    /// Canonical workspace represented by this frame.
    public let scope: WorkspacePresenceScope
    /// Server-owned cadence for renewing the viewing lease.
    public let renewAfterMs: Int
    /// Distinct active collaborators, including this account when viewing.
    public let participants: [WorkspacePresenceParticipant]

    /// Creates one room snapshot.
    public init(scope: WorkspacePresenceScope, participants: [WorkspacePresenceParticipant], renewAfterMs: Int = 15_000) {
        type = "workspace.presence"
        version = 1
        self.scope = scope
        self.participants = participants
        self.renewAfterMs = renewAfterMs
    }

    /// Validates the frame before installing it into the current room.
    /// - Parameter expectedScope: Scope captured when this connection opened.
    /// - Returns: Whether the frame respects protocol bounds and room identity.
    public func isValid(for expectedScope: WorkspacePresenceScope) -> Bool {
        type == "workspace.presence" && version == 1 && scope == expectedScope
            && (1_000...15_000).contains(renewAfterMs) && participants.count <= 128
            && participants.allSatisfy { !$0.id.isEmpty && $0.id.utf8.count <= 128 }
            && Set(participants.map(\.id)).count == participants.count
    }
}
