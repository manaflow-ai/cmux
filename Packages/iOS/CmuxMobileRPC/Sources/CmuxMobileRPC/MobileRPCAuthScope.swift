import Foundation
import os

/// Revocable identity for one signed-in RPC authorization epoch.
///
/// The shell rotates the relevant value synchronously when the signed-in account
/// or manual-host network trust epoch changes. Token acquisition and transport enqueue use
/// it as a non-secret key so requests from different auth epochs never share an
/// in-flight credential task.
///
/// `rawValue` is immutable and the only mutable field is accessed exclusively
/// through `isRevokedLock`, so the unchecked sendability has no cross-task race.
public final class MobileRPCAuthScope: @unchecked Sendable, Hashable {
    private let rawValue: UUID
    // lint:allow lock - scope revocation and writer admission must be synchronous;
    // an actor hop would recreate the authorization TOCTOU this flag closes.
    private let isRevokedLock = OSAllocatedUnfairLock(initialState: false)

    /// Creates a fresh authorization-scope identity.
    public init() {
        rawValue = UUID()
    }

    /// Revokes this epoch synchronously so no later queued write can begin sending.
    public func revoke() {
        isRevokedLock.withLock { $0 = true }
    }

    /// Acquires authorization for one send if revocation has not linearized first.
    func beginSend() -> MobileRPCSendLease? {
        isRevokedLock.withLock { isRevoked in
            guard !isRevoked else { return nil }
            return MobileRPCSendLease()
        }
    }

    /// Returns whether two scopes represent the same authorization epoch.
    public static func == (lhs: MobileRPCAuthScope, rhs: MobileRPCAuthScope) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    /// Hashes the authorization epoch identity into the supplied hasher.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}
