import Foundation

/// The request body to mark a workspace as read up to a given event sequence.
public struct MobileMarkReadRequest: Encodable, Equatable, Sendable {
    /// The team slug or identifier the workspace belongs to.
    public let teamSlugOrId: String

    /// The workspace identifier to mark read.
    public let workspaceId: String

    /// The latest event sequence read, or `nil` to mark fully read.
    public let latestEventSeq: Int?

    /// Creates a mark-read request.
    ///
    /// - Parameters:
    ///   - teamSlugOrId: The team slug or identifier the workspace belongs to.
    ///   - workspaceId: The workspace identifier to mark read.
    ///   - latestEventSeq: The latest event sequence read, or `nil` to mark fully read.
    public init(teamSlugOrId: String, workspaceId: String, latestEventSeq: Int?) {
        self.teamSlugOrId = teamSlugOrId
        self.workspaceId = workspaceId
        self.latestEventSeq = latestEventSeq
    }
}
