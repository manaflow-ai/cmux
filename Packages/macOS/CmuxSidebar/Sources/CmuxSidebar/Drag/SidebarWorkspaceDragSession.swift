public import Foundation

/// Immutable identity for one process-wide native workspace drag.
public struct SidebarWorkspaceDragSession: Equatable, Sendable {
    /// The pasteboard type shared by native sidebar workspace sources and drops.
    public static let pasteboardTypeIdentifier = "com.cmux.sidebar-tab-reorder"

    /// The stable prefix used by legacy sidebar drop consumers.
    public static let pasteboardPrefix = "cmux.sidebar-tab."

    /// Delimiter separating the legacy workspace id from the session token.
    public static let sessionDelimiter: Character = "#"

    /// Generation token that prevents stale completion from ending a newer drag.
    public let id: UUID

    /// Workspace or durable empty-group identity represented by the drag.
    public let workspaceId: UUID

    /// Creates a tokenized workspace drag session.
    /// - Parameters:
    ///   - id: Generation token for this drag. Defaults to a fresh UUID.
    ///   - workspaceId: Workspace represented by the drag.
    public init(id: UUID = UUID(), workspaceId: UUID) {
        self.id = id
        self.workspaceId = workspaceId
    }

    /// The process-local payload value written to the drag pasteboard.
    public var pasteboardValue: String {
        "\(Self.pasteboardPrefix)\(workspaceId.uuidString)\(Self.sessionDelimiter)\(id.uuidString)"
    }

}
