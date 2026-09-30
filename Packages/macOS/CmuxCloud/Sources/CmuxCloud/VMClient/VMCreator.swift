import Foundation

/// Who made a Cloud machine, for display only.
///
/// `/api/vm` is scoped by owner team, so on a team every member sees every
/// member's machines. Without this the sidebar shows a pile of generated
/// three-word names with nothing to tell them apart by.
///
/// `userId` is the stable part and is always present. `displayName` is nil
/// when nothing has recorded a name for that account: the backend writes its
/// identity snapshot when an account resolves and deletes it when that account
/// revokes a lease, so a teammate who just revoked one reads as unnamed until
/// they next sign in. The id is kept in that case so rows by the same person
/// still group together instead of collapsing into one anonymous bucket.
///
/// Nothing here is an authorization input. The caller is already entitled to
/// every machine it was sent.
public struct VMCreator: Equatable, Hashable, Sendable {
    public init(userId: String, displayName: String? = nil) {
        self.userId = userId
        self.displayName = displayName
    }

    public let userId: String

    /// Nil when no name is known. Never the raw account id: an opaque id in
    /// place of a name is the same unreadable list this is meant to fix.
    public let displayName: String?
}

extension VMCreator {
    /// Reads `createdBy` out of one `GET /api/vm` item.
    ///
    /// Returns nil for a missing or blank id, which covers both a control
    /// plane that predates the field and a malformed entry. An author is
    /// decoration on a row, so a bad one is dropped rather than failing the
    /// whole list decode the way a missing `id` or `provider` does.
    public init?(vmResponse: [String: Any]) {
        guard let raw = vmResponse["createdBy"] as? [String: Any] else { return nil }
        guard let userId = (raw["userId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userId.isEmpty
        else { return nil }
        let displayName = (raw["displayName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            userId: userId,
            displayName: displayName.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
