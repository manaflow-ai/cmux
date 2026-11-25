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
/// snapshots, the Home rows and chats kept to show at once; and it puts the account's
/// preferences away under its id. Pushes stop before the session ends
/// (`willSignOut`), so a signed-out phone gets no notifications.
@MainActor
public struct AccountSignOut {
    public var lastKnownLists: LastKnownListStore
    public var snapshots: LiveSnapshotStore
    public var feedStore: FeedStore
    public var removeFeedArchives: (String) -> Void
    public var readMarks: (String) -> FeedReadMarks
    public var preferences: AccountPreferences
    public var discardChiefTranscripts: @MainActor () -> Void
    /// The lists and chats kept so they show at once (each Mac's Home rows, its Agent Chats
    /// list, every agent chat's newest messages): none of them stays for the next account.
    public var discardKeptChats: @MainActor () -> Void

    public init(lastKnownLists: LastKnownListStore = .standard, snapshots: LiveSnapshotStore = .standard, feedStore: FeedStore = .shared,
                removeFeedArchives: @escaping (String) -> Void = FeedArchive.removeAll,
                readMarks: @escaping (String) -> FeedReadMarks = FeedReadMarks.forAccount,
                preferences: AccountPreferences = .standard,
                discardChiefTranscripts: @escaping @MainActor () -> Void = {
                    // Every kept Chief conversation goes, and neither session shows one.
                    ChiefSession.shared.discardTranscripts()
                    ChiefSession.cloud.discardTranscripts()
                },
                discardKeptChats: @escaping @MainActor () -> Void = {
                    MacHomeFeed.shared.discardForSignOut()
                    AgentChatsMemory.shared.removeAll()
                    AgentCatalogCache.shared.removeAll()
                    AgentTranscriptCache.standard.removeAll()
                }) {
        self.lastKnownLists = lastKnownLists
        self.snapshots = snapshots
        self.feedStore = feedStore
        self.removeFeedArchives = removeFeedArchives
        self.readMarks = readMarks
        self.preferences = preferences
        self.discardChiefTranscripts = discardChiefTranscripts
        self.discardKeptChats = discardKeptChats
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
            removeFeedArchives(userID)
            preferences.stash(userID: userID)
            if session?.accountDeleted == true {
                preferences.forget(userID: userID)
                readMarks(userID).remove()
            }
        }
        lastKnownLists.removeAll()
        snapshots.removeAll()
        discardChiefTranscripts()
        discardKeptChats()
    }
}
