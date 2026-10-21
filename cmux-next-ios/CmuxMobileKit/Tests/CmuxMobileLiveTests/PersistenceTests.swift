import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileTransport
import CryptoKit
import Foundation
import Testing
@testable import CmuxMobileLive

/// verify/persistence.md: sign-out keeps this iPhone's identity and its Macs'
/// approvals; "Remove This iPhone from My Macs" is the one action that ends them;
/// one account never sees another's state.
@Suite struct DeviceIdentityPersistenceTests {
    let service = "test.device"

    @Test func theSameAccountKeepsItsIdsAndAnotherGetsItsOwn() {
        let store = MemorySecretStore()
        let first = DeviceIdentity.load(userID: "user-a", store: store, service: service)
        #expect(first.link != first.presence)
        // A relaunch, or a sign-out and the same account signing in again.
        #expect(DeviceIdentity.load(userID: "user-a", store: store, service: service) == first)
        // Another account on this phone: other ids (the service binds an id to its first user).
        let other = DeviceIdentity.load(userID: "user-b", store: store, service: service)
        #expect(other.link != first.link && other.presence != first.presence)
        #expect(DeviceIdentity.load(userID: "user-a", store: store, service: service) == first)
    }

    @Test func theIdsOfAnEarlierBuildBelongToTheAccountSignedInNow() throws {
        let store = MemorySecretStore()
        try store.write(Data("11111111-1111-1111-1111-111111111111".utf8), service: service, account: "link")
        try store.write(Data("22222222-2222-2222-2222-222222222222".utf8), service: service, account: "presence")
        let adopted = DeviceIdentity.load(userID: "user-a", store: store, service: service)
        #expect(adopted == DeviceIdentity(link: "11111111-1111-1111-1111-111111111111", presence: "22222222-2222-2222-2222-222222222222"))
        #expect(store.accounts(service: service) == ["link.user-a", "presence.user-a"])
        // Adopted once: another account does not get them too.
        #expect(DeviceIdentity.load(userID: "user-b", store: store, service: service).link != adopted.link)
    }

    /// Builds up to 1.2.0 kept the ids under the pre-rename service: the first load moves them,
    /// so the Macs that approved this phone still know it.
    @Test func theIdsUnderThePreRenameServiceMoveToTheNewOne() throws {
        let store = MemorySecretStore()
        let legacy = DeviceIdentity.legacyService
        try store.write(Data("11111111-1111-1111-1111-111111111111".utf8), service: legacy, account: "link.user-a")
        try store.write(Data("22222222-2222-2222-2222-222222222222".utf8), service: legacy, account: "presence.user-a")
        let moved = DeviceIdentity.load(userID: "user-a", store: store)
        #expect(moved == DeviceIdentity(link: "11111111-1111-1111-1111-111111111111", presence: "22222222-2222-2222-2222-222222222222"))
        #expect(store.accounts(service: legacy).isEmpty)
        #expect(store.accounts(service: DeviceIdentity.defaultService) == ["link.user-a", "presence.user-a"])
        #expect(DeviceIdentity.load(userID: "user-a", store: store) == moved)
        // Another account's ids stay where they are until that account signs in.
        try store.write(Data("33333333-3333-3333-3333-333333333333".utf8), service: legacy, account: "link.user-b")
        #expect(DeviceIdentity.load(userID: "user-b", store: store).link == "33333333-3333-3333-3333-333333333333")
    }

    /// Before the first unlock the old service can't be read: no new id is stored over it, and
    /// the next launch still moves the approved one.
    @Test func aLockedLegacyIdIsNeverShadowed() throws {
        final class LockedLegacy: DeviceSecretStore, @unchecked Sendable {
            let inner = MemorySecretStore()
            var locked = true
            func read(service: String, account: String) throws -> Data? {
                if locked, service == DeviceIdentity.legacyService { throw KeychainSecretStore.Failure(status: -25308) }
                return try inner.read(service: service, account: account)
            }
            func write(_ data: Data, service: String, account: String) throws { try inner.write(data, service: service, account: account) }
            func delete(service: String, account: String) { inner.delete(service: service, account: account) }
        }
        let store = LockedLegacy()
        try store.inner.write(Data("11111111-1111-1111-1111-111111111111".utf8), service: DeviceIdentity.legacyService, account: "link.user-a")
        let locked = DeviceIdentity.load(userID: "user-a", store: store)
        #expect(locked.link != "11111111-1111-1111-1111-111111111111")
        #expect(store.inner.accounts(service: DeviceIdentity.defaultService).isEmpty)
        store.locked = false
        #expect(DeviceIdentity.load(userID: "user-a", store: store).link == "11111111-1111-1111-1111-111111111111")
    }

    /// A Keychain read that fails (say before the first unlock) never replaces the stored id.
    @Test func anUnreadableIdIsNeverReplaced() throws {
        final class Locked: DeviceSecretStore, @unchecked Sendable {
            let inner = MemorySecretStore()
            var locked = false
            func read(service: String, account: String) throws -> Data? {
                if locked { throw KeychainSecretStore.Failure(status: -25308) }
                return try inner.read(service: service, account: account)
            }
            func write(_ data: Data, service: String, account: String) throws { try inner.write(data, service: service, account: account) }
            func delete(service: String, account: String) { inner.delete(service: service, account: account) }
        }
        let store = Locked()
        let first = DeviceIdentity.load(userID: "user-a", store: store, service: service)
        store.locked = true
        #expect(DeviceIdentity.load(userID: "user-a", store: store, service: service).link != first.link)
        store.locked = false
        #expect(DeviceIdentity.load(userID: "user-a", store: store, service: service) == first)
    }

    @Test func aSignedOutLaunchDiscardsAnOlderBuildsIds() throws {
        let store = MemorySecretStore()
        try store.write(Data("11111111-1111-1111-1111-111111111111".utf8), service: service, account: "link")
        DeviceIdentity.discardLegacy(store: store, service: service)
        #expect(DeviceIdentity.load(userID: "user-b", store: store, service: service).link != "11111111-1111-1111-1111-111111111111")
    }

    @Test func accountDeletionForgetsOnlyThatAccountsIds() {
        let store = MemorySecretStore()
        let a = DeviceIdentity.load(userID: "user-a", store: store, service: service)
        let b = DeviceIdentity.load(userID: "user-b", store: store, service: service)
        DeviceIdentity.forget(userID: "user-a", store: store, service: service)
        #expect(DeviceIdentity.load(userID: "user-a", store: store, service: service).link != a.link)
        #expect(DeviceIdentity.load(userID: "user-b", store: store, service: service) == b)
    }
}

@Suite struct PhoneKeysPersistenceTests {
    let service = "test.phone-keys"

    func keys(_ user: String?, _ store: MemorySecretStore) -> PhoneKeys {
        PhoneKeys(userID: user, service: service, store: store, enclave: false)
    }

    func publicKeys(_ user: String?, _ store: MemorySecretStore) throws -> [String] {
        let pair = try keys(user, store).publicKeys()
        return [pair.identity, pair.approval]
    }

    @Test func theSameAccountKeepsItsKeysAndAnotherGetsItsOwn() throws {
        let store = MemorySecretStore()
        let first = try publicKeys("user-a", store)
        // A new instance (relaunch, or sign-out and sign-in): the keys the Mac approved.
        #expect(try publicKeys("user-a", store) == first)
        #expect(try publicKeys("user-b", store)[0] != first[0])
        #expect(try publicKeys("user-a", store) == first)
    }

    @Test func resetMakesNewKeysForThatAccountOnly() throws {
        let store = MemorySecretStore()
        let a = keys("user-a", store)
        let before = try a.publicKeys()
        let b = try publicKeys("user-b", store)
        a.reset()
        #expect(!a.hasStoredKeys)
        let after = try a.publicKeys()
        #expect(after.identity != before.identity && after.approval != before.approval)
        #expect(try publicKeys("user-b", store) == b)
    }

    @Test func theKeysOfAnEarlierBuildBelongToTheAccountSignedInNow() throws {
        let store = MemorySecretStore()
        let legacy = try publicKeys(nil, store)
        #expect(try publicKeys("user-a", store) == legacy)
        #expect(store.accounts(service: service) == ["approval.user-a", "identity.user-a"])
    }
}

/// The explicit removal: the Mac is asked, over the link, to forget this phone,
/// with the identity key's signature (cmux-mobile-host `pairing.rs` `unpair`).
@Suite struct RemoveThisPhoneUnpairTests {
    final class AuthChannel: LinkChannel, @unchecked Sendable {
        let id: UInt32 = 1
        private let lock = NSLock()
        private var inbox: [Data]
        private(set) var sent: [Data] = []
        init(_ first: JSONValue) { inbox = [try! JSONEncoder().encode(first)] }
        func send(_ data: Data) async throws {
            lock.withLock {
                sent.append(data)
                inbox.append(Data(#"{"ok":true}"#.utf8))
            }
        }
        func receive() async throws -> Data? { lock.withLock { inbox.isEmpty ? nil : inbox.removeFirst() } }
        func close(code: String, reason: String) async {}
    }

    final class RecordingLink: MacLink, @unchecked Sendable {
        let transport: CmuxMobileTransport.TransportKind = .webRTC
        let states: AsyncStream<LinkState> = AsyncStream { $0.finish() }
        let channel: AuthChannel
        private(set) var opened: [(String, [String: String])] = []
        init(_ channel: AuthChannel) { self.channel = channel }
        func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
            opened.append((service, args))
            return channel
        }
        func ping() async throws -> UInt32 { 1 }
        func close() async {}
    }

    @Test func theMacIsAskedToForgetThisPhoneWithASignedUnpair() async throws {
        let keys = PhoneKeys(userID: "user-a", service: "test.unpair", store: MemorySecretStore(), enclave: false)
        let pairing = LinkPairing(keys: keys, phoneID: "phone-1", name: "iPhone", pins: MacPins(file: nil))
        let channel = AuthChannel(.object(["challenge": .string("nonce-1"), "mac": .string("mac-1")]))
        let link = RecordingLink(channel)
        await pairing.unpair(link: link, macID: "mac-1")
        let (identity, approval) = try keys.publicKeys()
        #expect(link.opened.map(\.0) == ["auth"])
        #expect(link.opened.first?.1 == ["identityKey": identity, "approvalKey": approval, "name": "", "action": "unpair"])
        let sent = try #require(channel.sent.first)
        let reply = try JSONDecoder().decode(JSONValue.self, from: sent)
        let signatureHex = try #require(reply["signature"]?.stringValue)
        let signature = try #require(Data(hex: signatureHex))
        let message = LinkAuthPayload(mac: "mac-1", phone: "phone-1", nonce: "nonce-1", identityKey: identity,
                                      approvalKey: approval, action: "unpair").message
        let identityBytes = try #require(Data(hex: identity))
        let key = try P256.Signing.PublicKey(x963Representation: identityBytes)
        #expect(key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: message))
    }
}

@MainActor
@Suite struct AccountSignOutTests {
    @MainActor final class Tally: @unchecked Sendable { var count = 0 } // crash-allow: main actor only

    final class Session: SignOutSession {
        var stops = 0
        var removals = 0
        var accountDeleted = false
        func stop() { stops += 1 }
        func removeThisPhoneFromMacs() async { removals += 1 }
    }

    @MainActor struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-signout-\(UUID().uuidString)")
        let defaults: UserDefaults
        let feed = FeedStore(items: [])

        init() {
            let suite = "cmux-mobile-signout-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            snapshots = LiveSnapshotStore(directory: directory.appending(path: "snapshots"))
        }

        func archive(_ user: String) -> FeedArchive { FeedArchive(url: directory.appending(path: "feed-\(user).json")) }
        func marks(_ user: String) -> FeedReadMarks { FeedReadMarks(url: directory.appending(path: "read-\(user).json")) }
        let snapshots: LiveSnapshotStore
    }

    static func item(_ id: String) -> FeedItem {
        FeedItem(id: id, kind: .finished, workspaceID: "w", tabID: "t", agentName: "Claude", harness: "claude",
                 workspaceTitle: "w", markdown: "done", quote: nil, createdAt: Date())
    }

    func signOut(_ f: Fixture, chief: @escaping @MainActor () -> Void = {}) -> AccountSignOut {
        AccountSignOut(snapshots: f.snapshots, feedStore: f.feed, feedArchive: f.archive, readMarks: f.marks,
                       preferences: AccountPreferences(defaults: f.defaults), discardChiefOutbox: chief)
    }

    @Test func signOutKeepsTheMacsApprovalAndTheDeviceIdentity() async throws {
        let f = Fixture()
        let secrets = MemorySecretStore()
        let identity = DeviceIdentity.load(userID: "user-a", store: secrets)
        let keys = try PhoneKeys(userID: "user-a", service: "test.signout", store: secrets, enclave: false).publicKeys().identity
        let session = Session()
        let pushes = Tally()
        let plan = signOut(f)
        await plan.willSignOut { pushes.count += 1 }()
        plan.signedOut(userID: "user-a", session: session)
        #expect(pushes.count == 1)
        #expect(session.stops == 1)
        #expect(session.removals == 0)
        // The same account signing in again: the same phone, with the keys its Macs approved.
        #expect(DeviceIdentity.load(userID: "user-a", store: secrets) == identity)
        #expect(try PhoneKeys(userID: "user-a", service: "test.signout", store: secrets, enclave: false).publicKeys().identity == keys)
    }

    @Test func signOutDropsTheAccountsFeedSnapshotsAndUnsentChief() throws {
        let f = Fixture()
        let item = Self.item("e1")
        f.feed.replaceAll([item])
        f.archive("user-a").save([item])
        f.snapshots.save(LiveSnapshot(teamID: "t", teamName: "T", macs: [], linkedMacID: nil, workspaces: [:]), accountID: "user-a")
        f.snapshots.flush()
        let discards = Tally()
        signOut(f) { discards.count += 1 }.signedOut(userID: "user-a", session: Session())
        f.snapshots.flush()
        #expect(f.feed.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.archive("user-a").url.path))
        #expect(f.snapshots.load(accountID: "user-a") == nil)
        #expect(discards.count == 1)
    }

    @Test func preferencesComeBackForTheSameAccountOnly() {
        let f = Fixture()
        let prefs = AccountPreferences(defaults: f.defaults)
        prefs.activate(userID: "user-a")
        f.defaults.set(true, forKey: "cmuxMobile.setupComplete")
        f.defaults.set("mac-1", forKey: "cmuxMobile.live.mac.team-1")
        signOut(f).signedOut(userID: "user-a", session: Session())
        #expect(f.defaults.object(forKey: "cmuxMobile.setupComplete") == nil)
        // Another account: starts clean.
        prefs.activate(userID: "user-b")
        #expect(f.defaults.object(forKey: "cmuxMobile.setupComplete") == nil)
        #expect(f.defaults.string(forKey: "cmuxMobile.live.mac.team-1") == nil)
        f.defaults.set("mac-9", forKey: "cmuxMobile.live.mac.team-1")
        signOut(f).signedOut(userID: "user-b", session: Session())
        // The first account again: its setup and its Mac.
        prefs.activate(userID: "user-a")
        #expect(f.defaults.bool(forKey: "cmuxMobile.setupComplete"))
        #expect(f.defaults.string(forKey: "cmuxMobile.live.mac.team-1") == "mac-1")
    }

    @Test func aDeletedAccountKeepsNothing() {
        let f = Fixture()
        let prefs = AccountPreferences(defaults: f.defaults)
        prefs.activate(userID: "user-a")
        f.defaults.set(true, forKey: "cmuxMobile.setupComplete")
        f.marks("user-a").save(["e1"])
        let session = Session()
        session.accountDeleted = true
        signOut(f).signedOut(userID: "user-a", session: session)
        prefs.activate(userID: "user-a")
        #expect(f.defaults.object(forKey: "cmuxMobile.setupComplete") == nil)
        #expect(f.marks("user-a").load().isEmpty)
    }

    @Test func feedReadMarksAreKeptPerAccount() {
        let f = Fixture()
        f.marks("user-a").save(["e1"])
        f.feed.useReadMarks(f.marks("user-b"))
        f.feed.replaceAll([Self.item("e1")])
        #expect(f.feed.items.first?.isRead == false)
        f.feed.clearForSignOut()
        f.feed.useReadMarks(f.marks("user-a"))
        f.feed.replaceAll([Self.item("e1")])
        #expect(f.feed.items.first?.isRead == true)
    }
}

// The coordinator is iOS-only: this runs in the iOS simulator test pass.
#if os(iOS)
@MainActor
@Suite struct RemoveThisPhoneCoordinatorTests {
    @Test func removalReplacesTheKeysAndKeepsTheDeviceIdentity() async throws {
        let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
        ServiceStub.install(host: host) { _ in nil }
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-remove-\(UUID().uuidString)")
        let secrets = MemorySecretStore()
        let keys = PhoneKeys(userID: "user-a", service: "test.remove", store: secrets, enclave: false)
        let before = try keys.publicKeys().identity
        let identity = DeviceIdentity.load(userID: "user-a", store: secrets)
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let live = LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: identity, userID: "user-a", deviceName: "iPhone", transport: .webRTC,
            dialer: MockDialer(fail: true), feedStore: FeedStore(items: []), keys: keys,
            snapshots: LiveSnapshotStore(directory: directory), secrets: secrets,
            readMarks: FeedReadMarks(url: directory.appending(path: "read.json"))
        )
        defer { live.stop() }
        await live.removeThisPhoneFromMacs()
        #expect(live.removedFromMacsCount == 1)
        // New keys: every Mac that approved the old ones asks again.
        #expect(try keys.publicKeys().identity != before)
        // Still the same phone to the service.
        #expect(DeviceIdentity.load(userID: "user-a", store: secrets) == identity)
    }
}
#endif
