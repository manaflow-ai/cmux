import CmuxSurfaceCatalogModel
import Foundation

/// A bounded, read-only projection of existing work owners for CLI and Find Work.
struct CurrentWorkSnapshot: Codable, Sendable {
    var schemaVersion = 1
    var authority = "read_only_projection"
    var observedAt: String
    var totalObserved: Int
    var truncated: Bool
    var ownerAvailability: [String: String]
    var unsupportedFacts = ["durable_work_identity", "review_threads", "check_runs", "review_dispositions"]
    var items: [Item]

    struct Evidence: Codable, Sendable {
        var owner: String
        var reference: String
        var observedAt: String
    }

    struct Freshness: Codable, Sendable {
        var state: String
        var reason: String?
        /// Time this owner state was read, not the time a remote graph was produced.
        var observedAt: String
    }

    struct Placement: Codable, Sendable {
        var kind: String
        var machine: String
    }

    struct Projection: Codable, Sendable {
        var resourceRef: String
        var workspaceID: UUID
        var panelID: UUID
        var stableSurfaceID: UUID?
        var stableWorkspaceID: UUID?
        var remoteWorkspaceID: String?
        var remoteTabID: String?
    }

    struct Agent: Codable, Sendable {
        var sessionID: String?
        var kind: String?
        var state: String
        var hasHookLifecycleState: Bool
        var version: Int?
        var lastActivityAt: String?
        var evidence: Evidence
    }

    struct Attention: Codable, Sendable {
        var kind: String
        var scope: String
        var evidence: Evidence
    }

    struct PullRequest: Codable, Sendable {
        var number: Int
        var url: String
        var label: String
        var status: String
        var associationScope = "workspace"
        var workspaceID: UUID
        var freshness: Freshness
        var evidence: Evidence
    }

    struct Obligation: Codable, Sendable {
        var kind: String
        var possibleHumanObligation = true
        var freshness: Freshness
        var evidence: Evidence
    }

    struct Receipt: Codable, Sendable {
        var kind: String
        var cursor: CloudVMCursor?
        var evidence: Evidence
    }

    struct Item: Codable, Sendable {
        var resourceRef: String
        /// Only a local resource can inherit its single durable surface identity.
        var durableSurfaceID: UUID?
        var label: String
        var kind: String
        var lifecycle: String
        var placement: Placement
        var projections: [Projection]
        var cwd: String?
        var projectHints: [String]
        var repositoryHints: [String]
        var agents: [Agent]
        var attention: [Attention]
        var pullRequests: [PullRequest]
        var freshness: Freshness
        var cursor: CloudVMCursor?
        var receiptRefs: [Receipt]
        var possibleHumanObligations: [Obligation]
        var evidence: [Evidence]
        var omitted: [String: Int]
    }

    /// The socket and human consumers receive this same schema, without runtime owners.
    func jsonObject() throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(self)
        guard data.count <= 2_000_000 else {
            throw SurfaceCatalogError.unsupported("Current-work response exceeds 2 MB; request a smaller limit")
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
