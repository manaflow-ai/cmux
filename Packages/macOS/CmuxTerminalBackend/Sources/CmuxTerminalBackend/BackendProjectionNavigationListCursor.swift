internal import Foundation

/// Opaque progress fence for one projection-navigation list snapshot.
struct BackendProjectionNavigationListCursor: Codable, Equatable, Sendable {
    /// The exact client-state revision being paginated.
    let clientRevision: UInt64

    /// The last logical-presentation identifier returned by the preceding page.
    let afterLogicalPresentationID: UUID

    /// Creates one continuation cursor.
    ///
    /// - Parameters:
    ///   - clientRevision: The exact client-state revision being paginated.
    ///   - afterLogicalPresentationID: The final identifier already returned.
    init(clientRevision: UInt64, afterLogicalPresentationID: UUID) {
        self.clientRevision = clientRevision
        self.afterLogicalPresentationID = afterLogicalPresentationID
    }

    private enum CodingKeys: String, CodingKey {
        case clientRevision = "client_revision"
        case afterLogicalPresentationID = "after_logical_presentation_id"
    }
}
