import Foundation

/// Stable ownership metadata that keeps global results attributable to a workspace.
public struct ArtifactOwnership: Codable, Equatable, Hashable, Sendable {
    /// The stable cmux workspace identifier, when the record is workspace-owned.
    public let workspaceID: String?
    /// A canonical project identifier, normally derived from the project root.
    public let projectID: String?
    /// The local project root used for path authorization, when known.
    public let projectRoot: String?
    /// A display-only workspace title captured at ingest time.
    public let workspaceTitle: String?

    /// Creates ownership metadata.
    public init(
        workspaceID: String? = nil,
        projectID: String? = nil,
        projectRoot: String? = nil,
        workspaceTitle: String? = nil
    ) {
        self.workspaceID = Self.trimmed(workspaceID)
        self.projectID = Self.trimmed(projectID)
        self.projectRoot = Self.trimmed(projectRoot)
        self.workspaceTitle = Self.trimmed(workspaceTitle)
    }

    /// Returns whether this record belongs to a workspace id.
    public func belongsToWorkspace(_ workspaceID: String) -> Bool {
        self.workspaceID == workspaceID
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Scope used by catalog listing and search operations.
public enum ArtifactScope: Equatable, Sendable {
    /// Records owned by one workspace.
    case workspace(String)
    /// Records for one project, across its workspaces.
    case project(String)
    /// Every permitted record in the local catalog.
    case global
}

extension ArtifactScope: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let value = try container.decodeIfPresent(String.self, forKey: .value)
        switch kind {
        case "workspace": self = .workspace(value ?? "")
        case "project": self = .project(value ?? "")
        default: self = .global
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .workspace(let value):
            try container.encode("workspace", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .project(let value):
            try container.encode("project", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .global:
            try container.encode("global", forKey: .kind)
        }
    }
}
