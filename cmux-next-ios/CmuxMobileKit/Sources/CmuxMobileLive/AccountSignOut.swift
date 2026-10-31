import CmuxMobileChief
import CmuxMobileFeed
import CmuxMobileModel
import Foundation

/// What a live session does that sign-out decides about.
@MainActor
public protocol SignOutSession: AnyObject {
    /// Stops discovery, presence and the link.
    func stop()
    /// Asks the Mac to forget this phone and deletes its keys. Never part of sign-out.
    func removeThisPhoneFromMacs() async
    /// The account was deleted in this session: nothing of it is kept.
    var accountDeleted: Bool { get }
}

#if os(iOS)
extension LiveCoordinator: SignOutSession {}
#endif

/// Sign-out on this phone (verify/persistence.md).
///
/// It keeps the phone's identity for the account: its device ids, its Secure
/// Enclave keys and the Macs it pinned, each kept per account. The Mac admits only a dial whose
/// backend-stamped `fromUserId` is its own user, from a device id that user
/// registered, proving keys that user approved; so another account signing in
/// here reaches none of those Macs, and the same account signing in again is
/// the phone its Macs already allowed, with no new prompt.
///
/// It drops what the account's data shows: the Feed's items, the workspace
/// snapshots, Chief messages not yet sent; and it puts the account's
/// preferences away under its id. Pushes stop before the session ends
/// (`willSignOut`), so a signed-out phone gets no notifications.
@MainActor
public struct AccountSignOut {
    public var snapshots: LiveSnapshotStore
    public var feedStore: FeedStore
    public var feedArchive: (String) -> FeedArchive
    public var readMarks: (String) -> FeedReadMarks
    public var preferences: AccountPreferences
    public var discardChiefOutbox: @MainActor () -> Void

    public init(snapshots: LiveSnapshotStore = .standard, feedStore: FeedStore = .shared,
                feedArchive: @escaping (String) -> FeedArchive = FeedArchive.forAccount,
                readMarks: @escaping (String) -> FeedReadMarks = FeedReadMarks.forAccount,
                preferences: AccountPreferences = .standard,
                discardChiefOutbox: @escaping @MainActor () -> Void = {
                    ChiefSession.shared.discardOutbox()
                    ChiefSession.cloud.discardOutbox()
                }) {
        self.snapshots = snapshots
        self.feedStore = feedStore
        self.feedArchive = feedArchive
        self.readMarks = readMarks
        self.preferences = preferences
        self.discardChiefOutbox = discardChiefOutbox
    }

    /// The hook that runs before the session ends: only pushes stop. It does
    /// not ask any Mac to forget this phone.
    public func willSignOut(unregisterPush: @escaping @MainActor @Sendable () async -> Void)
        -> @MainActor @Sendable () async -> Void {
        { await unregisterPush() }
    }

    /// A launch while signed out: on the first launch after an older build
    /// (no account recorded), its unkeyed device ids, keys, Mac pins and live
    /// preferences belonged to a session that ended without a sign-out here,
    /// so they are dropped instead of going to the next account.
    public func settleLaunchSignedOut(secrets: any DeviceSecretStore = KeychainSecretStore()) {
        guard preferences.settleSignedOut() else { return }
        DeviceIdentity.discardLegacy(store: secrets)
        PhoneKeys.discardLegacy(store: secrets)
        try? FileManager.default.removeItem(at: MacPins.standardURL)
    }

    /// After the session ended. `userID` is the account that signed out.
    public func signedOut(userID: String?, session: (any SignOutSession)?) {
        session?.stop()
        feedStore.clearForSignOut()
        if let userID {
            feedArchive(userID).remove()
            preferences.stash(userID: userID)
            if session?.accountDeleted == true {
                preferences.forget(userID: userID)
                readMarks(userID).remove()
            }
        }
        snapshots.removeAll()
        discardChiefOutbox()
    }
}
