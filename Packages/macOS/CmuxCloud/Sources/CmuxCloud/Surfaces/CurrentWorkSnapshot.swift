import CmuxSurfaceCatalogModel
import Foundation

/// A bounded, read-only projection of existing work owners for CLI and Find Work.
public struct CurrentWorkSnapshot: Codable, Sendable {
    public init(
        observedAt: String,
        totalObserved: Int,
        truncated: Bool,
        ownerAvailability: [String: String],
        items: [Item]
    ) {
        self.observedAt = observedAt
        self.totalObserved = totalObserved
        self.truncated = truncated
        self.ownerAvailability = ownerAvailability
        self.items = items
    }

    public var schemaVersion = 1
    public var authority = "read_only_projection"
    public var observedAt: String
    public var totalObserved: Int
    public var truncated: Bool
    public var ownerAvailability: [String: String]
    var unsupportedFacts = ["durable_work_identity", "review_threads", "check_runs", "review_dispositions"]
    public var items: [Item]

    public struct Evidence: Codable, Sendable {
        public init(
            owner: String,
            reference: String,
            observedAt: String
        ) {
            self.owner = owner
            self.reference = reference
            self.observedAt = observedAt
        }

        public var owner: String
        public var reference: String
        public var observedAt: String
    }

    public struct Freshness: Codable, Sendable {
        public init(
            state: String,
            reason: String?,
            observedAt: String
        ) {
            self.state = state
            self.reason = reason
            self.observedAt = observedAt
        }

        public var state: String
        public var reason: String?
        /// Time this owner state was read, not the time a remote graph was produced.
        public var observedAt: String
    }

    public struct Placement: Codable, Sendable {
        public init(
            kind: String,
            machine: String
        ) {
            self.kind = kind
            self.machine = machine
        }

        public var kind: String
        public var machine: String
    }

    public struct Projection: Codable, Sendable {
        public init(
            resourceRef: String,
            workspaceID: UUID,
            panelID: UUID,
            stableSurfaceID: UUID?,
            stableWorkspaceID: UUID?,
            remoteWorkspaceID: String?,
            remoteTabID: String?
        ) {
            self.resourceRef = resourceRef
            self.workspaceID = workspaceID
            self.panelID = panelID
            self.stableSurfaceID = stableSurfaceID
            self.stableWorkspaceID = stableWorkspaceID
            self.remoteWorkspaceID = remoteWorkspaceID
            self.remoteTabID = remoteTabID
        }

        public var resourceRef: String
        public var workspaceID: UUID
        public var panelID: UUID
        public var stableSurfaceID: UUID?
        public var stableWorkspaceID: UUID?
        public var remoteWorkspaceID: String?
        public var remoteTabID: String?
    }

    public struct Agent: Codable, Sendable {
        public init(
            sessionID: String?,
            kind: String?,
            state: String,
            hasHookLifecycleState: Bool,
            version: Int?,
            lastActivityAt: String?,
            evidence: Evidence
        ) {
            self.sessionID = sessionID
            self.kind = kind
            self.state = state
            self.hasHookLifecycleState = hasHookLifecycleState
            self.version = version
            self.lastActivityAt = lastActivityAt
            self.evidence = evidence
        }

        public var sessionID: String?
        public var kind: String?
        public var state: String
        public var hasHookLifecycleState: Bool
        public var version: Int?
        public var lastActivityAt: String?
        public var evidence: Evidence
    }

    public struct Attention: Codable, Sendable {
        public init(
            kind: String,
            scope: String,
            evidence: Evidence
        ) {
            self.kind = kind
            self.scope = scope
            self.evidence = evidence
        }

        public var kind: String
        public var scope: String
        public var evidence: Evidence
    }

    public struct PullRequest: Codable, Sendable {
        public init(
            number: Int,
            url: String,
            label: String,
            status: String,
            workspaceID: UUID,
            freshness: Freshness,
            evidence: Evidence
        ) {
            self.number = number
            self.url = url
            self.label = label
            self.status = status
            self.workspaceID = workspaceID
            self.freshness = freshness
            self.evidence = evidence
        }

        public var number: Int
        public var url: String
        public var label: String
        public var status: String
        public var associationScope = "workspace"
        public var workspaceID: UUID
        public var freshness: Freshness
        public var evidence: Evidence
    }

    public struct Obligation: Codable, Sendable {
        public init(
            kind: String,
            freshness: Freshness,
            evidence: Evidence
        ) {
            self.kind = kind
            self.freshness = freshness
            self.evidence = evidence
        }

        public var kind: String
        var possibleHumanObligation = true
        public var freshness: Freshness
        public var evidence: Evidence
    }

    public struct Receipt: Codable, Sendable {
        public init(
            kind: String,
            cursor: CloudVMCursor?,
            evidence: Evidence
        ) {
            self.kind = kind
            self.cursor = cursor
            self.evidence = evidence
        }

        public var kind: String
        public var cursor: CloudVMCursor?
        public var evidence: Evidence
    }

    public struct Item: Codable, Sendable {
        public init(
            resourceRef: String,
            durableSurfaceID: UUID?,
            label: String,
            kind: String,
            lifecycle: String,
            placement: Placement,
            projections: [Projection],
            cwd: String?,
            projectHints: [String],
            repositoryHints: [String],
            agents: [Agent],
            attention: [Attention],
            pullRequests: [PullRequest],
            freshness: Freshness,
            cursor: CloudVMCursor?,
            receiptRefs: [Receipt],
            possibleHumanObligations: [Obligation],
            evidence: [Evidence],
            omitted: [String: Int]
        ) {
            self.resourceRef = resourceRef
            self.durableSurfaceID = durableSurfaceID
            self.label = label
            self.kind = kind
            self.lifecycle = lifecycle
            self.placement = placement
            self.projections = projections
            self.cwd = cwd
            self.projectHints = projectHints
            self.repositoryHints = repositoryHints
            self.agents = agents
            self.attention = attention
            self.pullRequests = pullRequests
            self.freshness = freshness
            self.cursor = cursor
            self.receiptRefs = receiptRefs
            self.possibleHumanObligations = possibleHumanObligations
            self.evidence = evidence
            self.omitted = omitted
        }

        public var resourceRef: String
        /// Only a local resource can inherit its single durable surface identity.
        public var durableSurfaceID: UUID?
        public var label: String
        public var kind: String
        public var lifecycle: String
        public var placement: Placement
        public var projections: [Projection]
        public var cwd: String?
        public var projectHints: [String]
        public var repositoryHints: [String]
        public var agents: [Agent]
        public var attention: [Attention]
        public var pullRequests: [PullRequest]
        public var freshness: Freshness
        public var cursor: CloudVMCursor?
        public var receiptRefs: [Receipt]
        public var possibleHumanObligations: [Obligation]
        public var evidence: [Evidence]
        public var omitted: [String: Int]
    }

    /// The socket and human consumers receive this same schema, without runtime owners.
    public func jsonObject() throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(self)
        guard data.count <= 2_000_000 else {
            throw SurfaceCatalogError.unsupported("Current-work response exceeds 2 MB; request a smaller limit")
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
