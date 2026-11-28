import Foundation

/// Canonical identity of a shared workspace, independent of its local projection.
public struct WorkspacePresenceScope: Codable, Equatable, Hashable, Sendable {
    /// The authority that owns the workspace.
    public enum Kind: String, Codable, Sendable { case cloud, mac }
    /// Cloud VM or on-device workspace authority.
    public let kind: Kind
    /// VM id for Cloud, or the host's durable device id for on-device sharing.
    public let ownerID: String
    /// Exact Mac app tag; absent for a Cloud workspace shared across Mac clients.
    public let instanceTag: String?
    /// Workspace id allocated by its host, never a projecting client's row id.
    public let workspaceID: String
    /// Cloud team authority; on-device scopes remain private to the account.
    public let teamID: String?

    /// Creates a scope only when every identifier fits the wire contract.
    /// - Parameters:
    ///   - kind: Workspace authority.
    ///   - ownerID: Canonical host or VM id.
    ///   - instanceTag: Mac app tag; required only for a Mac scope.
    ///   - workspaceID: Host-owned workspace id.
    ///   - teamID: Cloud team's id; required only for a Cloud scope.
    public init?(kind: Kind, ownerID: String, instanceTag: String? = nil, workspaceID: String, teamID: String? = nil) {
        guard Self.valid(ownerID, limit: 128), Self.valid(workspaceID, limit: 128) else { return nil }
        switch kind {
        case .cloud:
            guard let teamID, Self.valid(teamID, limit: 128), instanceTag == nil else { return nil }
        case .mac:
            guard let instanceTag, Self.valid(instanceTag, limit: 64), teamID == nil,
                  UUID(uuidString: ownerID) != nil, UUID(uuidString: workspaceID) != nil else { return nil }
        }
        self.kind = kind
        self.ownerID = kind == .mac ? ownerID.lowercased() : ownerID
        self.instanceTag = instanceTag
        self.workspaceID = kind == .mac ? workspaceID.lowercased() : workspaceID
        self.teamID = teamID
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self(kind: try c.decode(Kind.self, forKey: .kind),
                               ownerID: try c.decode(String.self, forKey: .ownerID),
                               instanceTag: try c.decodeIfPresent(String.self, forKey: .instanceTag),
                               workspaceID: try c.decode(String.self, forKey: .workspaceID),
                               teamID: try c.decodeIfPresent(String.self, forKey: .teamID)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid workspace presence scope"))
        }
        self = value
    }

    private enum CodingKeys: String, CodingKey { case kind, ownerID, instanceTag, workspaceID, teamID }
    private static func valid(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
}
