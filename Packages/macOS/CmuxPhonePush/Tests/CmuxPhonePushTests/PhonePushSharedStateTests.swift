import CmuxAuthRuntime
import CryptoKit
import Foundation
import Testing
@testable import CmuxPhonePush

@Suite("Phone push shared state")
struct PhonePushSharedStateTests {
    /// Stands in for the keychain group the host app and its extension share.
    private final class MemoryStorage: PhonePushSharedStateStorage {
        var values: [String: Data] = [:]

        func data(forKey key: String) -> Data? { values[key] }

        func setData(_ data: Data?, forKey key: String) { values[key] = data }

        func keys(withPrefix prefix: String) -> [String] {
            values.keys.filter { $0.hasPrefix(prefix) }
        }
    }

    /// A bundle on disk with the Info.plist keys the host app or its
    /// extension ships.
    private func bundle(_ info: [String: String]) throws -> Bundle {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhonePushSharedStateTests-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Info.plist"))
        return try #require(Bundle(url: url))
    }

    private var hostBundle: Bundle {
        get throws { try bundle(["CFBundleIdentifier": "dev.cmux.app.internal"]) }
    }

    private var extensionBundle: Bundle {
        get throws {
            try bundle([
                "CFBundleIdentifier": "dev.cmux.app.internal.NotificationService",
                "CMUXHostBundleIdentifier": "dev.cmux.app.internal",
            ])
        }
    }

    private func tuple(macInstanceTag: String = "nightly") -> PhonePushDeviceTuple {
        PhonePushDeviceTuple(
            accountID: "account-1",
            teamID: nil,
            iosBuildID: "dev.cmux.app.internal",
            iosInstallationID: "ios-install-1",
            macDeviceID: "mac-1",
            macInstanceTag: macInstanceTag,
            macBuildID: "com.cmuxterm.app.nightly"
        )
    }

    @Test("the extension opens a push with state the host app wrote")
    func extensionOpensPushWithHostState() throws {
        let shared = MemoryStorage()
        let phoneKey = PhonePushKeyMaterial(
            installationID: "ios-install-1",
            keyID: "ios-key-1",
            privateKey: Curve25519.KeyAgreement.PrivateKey()
        )
        let macKey = PhonePushKeyMaterial(
            installationID: "mac-install-1",
            keyID: "mac-key-1",
            privateKey: Curve25519.KeyAgreement.PrivateKey()
        )
        let tuple = tuple()

        // Host app: sign-in records the account, key exchange pins the Mac.
        PhonePushActiveAccountStore(bundle: try hostBundle, storage: shared).set("account-1")
        PhonePushPeerKeyStore(storage: shared).pin(macKey.publicKeyData, keyID: macKey.keyID, for: tuple)

        // Mac: encrypt the notify request for the phone's installation.
        let payload = PhonePushPayload(
            kind: .notify,
            title: "Claude Code",
            subtitle: "",
            body: "Tests passed in cmux",
            replyShape: "none",
            workspaceId: "workspace-1",
            surfaceId: "surface-1",
            retargetsToLiveSurfaceOwner: false,
            macDeviceId: tuple.macDeviceID,
            macInstanceTag: tuple.macInstanceTag,
            notificationId: "notification-1",
            notificationIds: [],
            badgeCount: 1,
            hideContent: false
        )
        let expiration = Int(Date().timeIntervalSince1970) + 120
        let plaintext = try PhonePushRequestEnvelope(
            payload: payload,
            expirationEpochSeconds: expiration,
            expectedAccountID: "account-1",
            macPushPublicKey: macKey.publicKeyData.base64EncodedString(),
            macInstallationID: macKey.installationID,
            macBuildID: tuple.macBuildID
        ).body
        let envelope = try PhonePushCrypto().encrypt(
            plaintext: plaintext,
            tuple: tuple,
            recipientPublicKey: phoneKey.publicKeyData,
            keyID: phoneKey.keyID,
            senderKeyID: macKey.keyID,
            senderPrivateKey: macKey.privateKey,
            installationID: phoneKey.installationID
        )

        // Extension: separate store instances over the same shared storage.
        #expect(
            PhonePushActiveAccountStore(bundle: try extensionBundle, storage: shared).current()
                == envelope.tuple.accountID
        )
        let sender = try #require(PhonePushPeerKeyStore(storage: shared).pinnedDescriptor(for: envelope.tuple))
        let opened = try PhonePushCrypto().decrypt(
            envelope: envelope,
            tuple: envelope.tuple,
            recipientInstallationID: phoneKey.installationID,
            recipientKeyID: phoneKey.keyID,
            trustedSenderKeyID: sender.keyID,
            senderPublicKey: sender.publicKey,
            privateKey: phoneKey.privateKey
        )
        let object = try #require(JSONSerialization.jsonObject(with: opened) as? [String: Any])
        #expect(object["title"] as? String == "Claude Code")
        #expect(object["body"] as? String == "Tests passed in cmux")
        #expect((object["expirationEpochSeconds"] as? NSNumber)?.intValue == expiration)
    }

    @Test("clearing the account hides it from the extension")
    func clearedAccountIsGone() throws {
        let shared = MemoryStorage()
        PhonePushActiveAccountStore(bundle: try hostBundle, storage: shared).set("account-1")
        #expect(PhonePushActiveAccountStore(bundle: try extensionBundle, storage: shared).current() == "account-1")
        PhonePushActiveAccountStore(bundle: try hostBundle, storage: shared).clear()
        #expect(PhonePushActiveAccountStore(bundle: try extensionBundle, storage: shared).current() == nil)
    }

    private func mirroredAccount(
        after identities: [AuthenticatedSessionIdentity?],
        storage: MemoryStorage
    ) async throws -> String? {
        let (stream, continuation) = AsyncStream<AuthenticatedSessionIdentity?>.makeStream()
        for identity in identities { continuation.yield(identity) }
        continuation.finish()
        await PhonePushActiveAccountStore(bundle: try hostBundle, storage: storage).mirror(stream)
        return PhonePushActiveAccountStore(bundle: try extensionBundle, storage: storage).current()
    }

    @Test("a session restored at launch reaches the extension without a sign-in")
    func restoredSessionWritesAccount() async throws {
        let restored = AuthenticatedSessionIdentity(generation: 3, accountID: "account-1")
        #expect(try await mirroredAccount(after: [restored], storage: MemoryStorage()) == "account-1")
    }

    @Test("the mirrored account follows account switches and sign-out")
    func mirrorFollowsTransitions() async throws {
        let first = AuthenticatedSessionIdentity(generation: 1, accountID: "account-1")
        let second = AuthenticatedSessionIdentity(generation: 2, accountID: "account-2")
        #expect(try await mirroredAccount(after: [nil, first, second], storage: MemoryStorage()) == "account-2")

        let signedOut = MemoryStorage()
        PhonePushActiveAccountStore(bundle: try hostBundle, storage: signedOut).set("stale-account")
        #expect(try await mirroredAccount(after: [first, nil], storage: signedOut) == nil)
    }

    @Test("pins beyond the cap evict the least recently pinned Mac")
    func pinsEvictOldestPastCap() {
        let shared = MemoryStorage()
        let store = PhonePushPeerKeyStore(storage: shared)
        let first = tuple(macInstanceTag: "tag-0")
        store.pin(Data([0]), keyID: "key-0", for: first)
        for index in 1...128 {
            store.pin(Data([UInt8(index % 256)]), keyID: "key-\(index)", for: tuple(macInstanceTag: "tag-\(index)"))
        }
        #expect(store.pinnedDescriptor(for: first) == nil)
        #expect(store.pinnedDescriptor(for: tuple(macInstanceTag: "tag-1"))?.keyID == "key-1")
        #expect(store.pinnedDescriptor(for: tuple(macInstanceTag: "tag-128"))?.keyID == "key-128")
        #expect(shared.keys(withPrefix: "cmux.phone-push.peer.v2.").count == 129)
    }

    @Test("Mac pins stored by the previous defaults format keep working")
    func macDefaultsKeepLegacyPins() throws {
        let suite = "PhonePushSharedStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = PhonePushUserDefaultsStateStorage(defaults: defaults)
        let older = tuple(macInstanceTag: "older")
        let newer = tuple(macInstanceTag: "newer")
        PhonePushPeerKeyStore(storage: storage).pin(Data([1]), keyID: "older-key", for: older)
        PhonePushPeerKeyStore(storage: storage).pin(Data([2]), keyID: "newer-key", for: newer)

        // The registry used to be a plist string array.
        let registryKey = "cmux.phone-push.peer.v2.registry"
        let registry = try JSONDecoder().decode(
            [String].self,
            from: try #require(storage.data(forKey: registryKey))
        )
        defaults.set(registry, forKey: registryKey)

        #expect(PhonePushPeerKeyStore(storage: storage).pinnedDescriptor(for: older)?.keyID == "older-key")
        #expect(storage.data(forKey: registryKey).flatMap {
            try? JSONDecoder().decode([String].self, from: $0)
        } == registry)
    }

    @Test("the keychain group needs a resolved team prefix")
    func keychainAccessGroupResolution() {
        #expect(PhonePushKeychainStateStorage.accessGroup(from: "7WLXT3NR37.dev.cmux.app.internal")
            == "7WLXT3NR37.dev.cmux.app.internal")
        #expect(PhonePushKeychainStateStorage.accessGroup(from: "$(AppIdentifierPrefix)dev.cmux.app") == nil)
        #expect(PhonePushKeychainStateStorage.accessGroup(from: ".dev.cmux.app.internal") == nil)
        #expect(PhonePushKeychainStateStorage.accessGroup(from: "7WLXT3NR37.") == nil)
        #expect(PhonePushKeychainStateStorage.accessGroup(from: nil) == nil)
    }
}
