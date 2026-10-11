public import CmuxNextApps
import Foundation

/// Session answers for `per_session` scopes. Answers given before the
/// grant last narrowed do not count.
public nonisolated struct AppSessionApprovals: Sendable, Hashable, Codable {
    public var scopes: Set<String>
    /// The grant revision when the answers were given.
    public var grantRevision: UInt64

    public static let none = AppSessionApprovals(scopes: [], grantRevision: 0)

    public init(scopes: Set<String>, grantRevision: UInt64) {
        self.scopes = scopes
        self.grantRevision = grantRevision
    }

    /// Whether the session already approved `scope` under `grant`.
    public func covers(_ scope: String, grant: AppGrant) -> Bool {
        grantRevision >= grant.narrowedAt && scopes.contains(scope)
    }
}

/// A call admitted earlier and still running or waiting, stamped with the
/// grant revision it was checked against.
public nonisolated struct AppPendingCall: Sendable, Hashable {
    public var op: String
    public var params: AppJSON
    public var grantRevision: UInt64

    public init(op: String, params: AppJSON, grantRevision: UInt64) {
        self.op = op
        self.params = params
        self.grantRevision = grantRevision
    }
}
