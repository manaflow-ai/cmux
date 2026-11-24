import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "push-account")

/// The session that is currently permitted to reveal notifications in the
/// notification service extension. Pairing and per-account decrypt keys are
/// deliberately retained across sign-out; this marker has a different lifetime.
///
/// It lives in the same Keychain access group as PushKeys, readable by the
/// app and its service extension after first unlock. A missing or unreadable
/// marker always withholds rich content and actions.
public struct PushActiveAccount: Sendable {
    public let store: any PushSecretStore
    static let marker = "active-user-v1"

    public init(store: any PushSecretStore) { self.store = store }

    public static func current(bundle: Bundle = .main) -> PushActiveAccount? {
        PushKeychainStore.current(bundle: bundle).map(PushActiveAccount.init(store:))
    }

    public func userID() -> String? {
        guard let data = try? store.read(Self.marker),
              let user = String(data: data, encoding: .utf8), !user.isEmpty else { return nil }
        return user
    }

    /// Signed out (no marker) never permits. Signed in with no pairing record
    /// keeps the pre-marker behavior for Macs that do not seal; a record
    /// paired by another account is refused.
    public func permits(_ trust: PushTrust?) -> Bool {
        guard let user = userID() else { return false }
        guard let trust else { return true }
        return trust.user == user
    }

    public func update(userID: String?) throws {
        guard let userID, !userID.isEmpty else {
            // Overwrite with an inert value through the throwing Keychain API:
            // PushSecretStore.delete() has no status, so an unsuccessful delete
            // could leave the old account authorized without telling sign-out.
            try store.write(Data(), account: Self.marker)
            return
        }
        try store.write(Data(userID.utf8), account: Self.marker)
    }
}

/// Serializes auth changes without a blocking Keychain call on the main actor.
/// A sign-in restore updates the marker too; sign-out awaits the clear before
/// revoking network credentials. A later account's write follows the clear.
@MainActor
public final class PushActiveAccountMirror {
    public static let shared = PushActiveAccountMirror()

    private let account: PushActiveAccount?
    private var pending: Task<Void, Never>?

    public init(account: PushActiveAccount? = PushActiveAccount.current()) {
        self.account = account
    }

    @discardableResult
    public func update(userID: String?) -> Task<Void, Never> {
        let previous = pending
        let account = account
        let task = Task.detached(priority: .utility) {
            await previous?.value
            do { try account?.update(userID: userID) }
            catch { log.error("could not update notification account marker") }
        }
        pending = task
        return task
    }

    public func clearBeforeSignOut() async {
        await update(userID: nil).value
    }
}
