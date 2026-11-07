public import Foundation

/// A bounded snapshot of a repository's decorated commit history.
public struct GitGraphSnapshot: Sendable, Equatable {
    public let repositoryRoot: String
    public let branch: String?
    public let headOID: String?
    public let isDirty: Bool
    public let rows: [GitGraphRow]
    public let truncation: GitGraphTruncation

    public var isTruncated: Bool { truncation != .none }

    public init(
        repositoryRoot: String,
        branch: String?,
        headOID: String?,
        isDirty: Bool,
        rows: [GitGraphRow],
        truncation: GitGraphTruncation
    ) {
        self.repositoryRoot = repositoryRoot
        self.branch = branch
        self.headOID = headOID
        self.isDirty = isDirty
        self.rows = rows
        self.truncation = truncation
    }
}

/// The bound that prevented a Git graph snapshot from containing more history.
public enum GitGraphTruncation: Sendable, Equatable {
    case none
    case commitLimit
    case outputLimit
}

/// One commit and the graph lanes entering and leaving its row.
public struct GitGraphRow: Identifiable, Sendable, Equatable {
    public var id: String { commit.oid }
    public let commit: GitGraphCommit
    public let nodeLane: Int
    public let nodeColorIndex: Int
    public let incomingLanes: [GitGraphLane]
    public let outgoingLanes: [GitGraphLane]

    public init(
        commit: GitGraphCommit,
        nodeLane: Int,
        nodeColorIndex: Int,
        incomingLanes: [GitGraphLane],
        outgoingLanes: [GitGraphLane]
    ) {
        self.commit = commit
        self.nodeLane = nodeLane
        self.nodeColorIndex = nodeColorIndex
        self.incomingLanes = incomingLanes
        self.outgoingLanes = outgoingLanes
    }
}

/// A lane identity used to draw stable colors through a graph row.
public struct GitGraphLane: Sendable, Equatable {
    public let oid: String
    public let colorIndex: Int

    public init(oid: String, colorIndex: Int) {
        self.oid = oid
        self.colorIndex = colorIndex
    }
}

/// Immutable metadata for one Git commit.
public struct GitGraphCommit: Identifiable, Sendable, Equatable {
    public var id: String { oid }
    public let oid: String
    public let parentOIDs: [String]
    public let references: [GitGraphReference]
    public let author: String
    public let authoredAt: Date
    public let subject: String

    public init(
        oid: String,
        parentOIDs: [String],
        references: [GitGraphReference],
        author: String,
        authoredAt: Date,
        subject: String
    ) {
        self.oid = oid
        self.parentOIDs = parentOIDs
        self.references = references
        self.author = author
        self.authoredAt = authoredAt
        self.subject = subject
    }
}

/// A normalized local branch, remote branch, tag, or other decorated ref.
public struct GitGraphReference: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case head
        case branch
        case remote
        case tag
        case other
    }

    public var id: String { "\(kind.rawValue):\(name)" }
    public let name: String
    public let kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

/// Failures produced while resolving or reading a local Git repository.
public enum GitGraphServiceError: Error, Sendable, Equatable {
    case notRepository
    case commandFailed
}
