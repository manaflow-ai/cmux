#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
import Foundation
import Testing
@testable import CmuxMobileLive

/// The first launch after an App Store update from the classic app (the same bundle
/// id, com.cmux.app): its Keychain items and settings go once, this app's stay, and
/// the person signs in from a clean state.
@Suite struct ClassicLeftoversTests {
    /// A Keychain in memory, or one that cannot be read yet (before the first unlock).
    final class FakeKeychain: ClassicLeftovers.Keychain, @unchecked Sendable { // crash-allow: lock-guarded
        private let lock = NSLock()
        private var stored: [KeychainLeftover]
        var readable = true
        /// Services whose deletes fail (a readable Keychain that refuses a delete).
        var failingServices: Set<String> = []

        init(_ items: [(String?, String?)]) {
            stored = items.map { KeychainLeftover(service: $0.0, account: $0.1) }
        }

        var all: [KeychainLeftover] { lock.withLock { stored } }

        func items() -> [KeychainLeftover]? { lock.withLock { readable ? stored : nil } }

        func delete(service: String, account: String?) -> Bool {
            lock.withLock {
                if failingServices.contains(service) { return false }
                stored.removeAll { ($0.service ?? "") == service && (account == nil || $0.account == account) }
                return true
            }
        }

        func has(_ service: String, _ account: String? = nil) -> Bool {
            all.contains { $0.service == service && (account == nil || $0.account == account) }
        }
    }

    static let classicItems: [(String?, String?)] = [
        ("com.cmuxterm.app.auth.com.cmux.app", "cmux-auth-access-token"),
        ("com.cmuxterm.app.auth.com.cmux.app", "cmux-auth-refresh-token"),
        ("ai.manaflow.cmux.phone-push.com.cmux.app", "v1"),
        ("ai.manaflow.cmux.phone-push.shared-state", "cmux.phone-push.peer.v2.registry"),
        ("com.cmux.app.cmux-iroh-v2.installation", "device-id"),
        ("com.cmuxterm.deviceRegistry.iosDeviceID.v1.com.cmux.app", "default"),
        ("com.cmuxterm.cloud.wireguard.v1.com.cmux.app", "cloud-device-identity"),
        ("dev.cmux.ssh.keys", "8C1F"),
        (nil, "stack-auth-refresh-9790718f"),
    ]

    static var classicDefaults: [String: Any] { [
        "auth_has_tokens": true,
        "auth_cached_user": Data("{\"id\":\"classic-user\"}".utf8),
        "auth_stack_project_id": "9790718f",
        "cmux.iroh.pathPreference": "relayOnly",
        "cmux.notifications.deviceTokenHex": "ab",
        "presenceServiceURL": "https://presence.example",
        "sendAnonymousTelemetry": true,
    ] }

    func suite() throws -> (UserDefaults, String) {
        let name = "ClassicLeftoversTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func theFirstLaunchAfterAnUpdateStartsSignedOutWithNoClassicItemLeft() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        for (key, value) in Self.classicDefaults { defaults.set(value, forKey: key) }
        let keychain = FakeKeychain(Self.classicItems)

        let outcome = ClassicLeftovers.cleanUpIfDue(bundleIdentifier: "com.cmux.app", defaults: defaults,
                                                    domain: name, keychain: keychain)

        #expect(outcome.ran)
        #expect(outcome.keychainDeleted == Self.classicItems.count)
        #expect(outcome.defaultsDeleted == Self.classicDefaults.count)
        #expect(keychain.all.isEmpty)
        for key in Self.classicDefaults.keys { #expect(defaults.object(forKey: key) == nil, "\(key)") }
        // Nothing of a session for this app: its token service and its signed-in flag are empty.
        #expect(!keychain.has("com.cmux.app.auth"))
        #expect(defaults.object(forKey: "cmuxMobile.auth.hasTokens") == nil)
    }

    @Test func thisAppsOwnItemsAndUnknownOnesStay() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "auth_has_tokens")
        defaults.set(true, forKey: "cmuxMobile.setupComplete")
        defaults.set("team-1", forKey: "cnx.lastTeamID")
        defaults.set("kept", forKey: "some.sdk.key")
        let own: [(String?, String?)] = [
            ("com.cmux.app.auth", "cmux-auth-access-token"),
            ("com.cmux.app.phone-keys", "keys"),
            ("dev.cmux.mobile.device", "link.user-1"),
            ("dev.cmux.mobile.push", "preference.mutedChats"),
            ("com.example.sdk", "token"),
            (nil, nil),
            ("", "someone-elses"),
        ]
        let keychain = FakeKeychain(own + [("com.cmuxterm.app.auth.com.cmux.app", "cmux-auth-access-token")])

        let outcome = ClassicLeftovers.cleanUpIfDue(bundleIdentifier: "com.cmux.app", defaults: defaults,
                                                    domain: name, keychain: keychain)

        #expect(outcome.keychainDeleted == 1)
        #expect(outcome.defaultsDeleted == 1)
        #expect(keychain.all.count == own.count)
        #expect(keychain.has("com.cmux.app.auth", "cmux-auth-access-token"))
        #expect(defaults.bool(forKey: "cmuxMobile.setupComplete"))
        #expect(defaults.string(forKey: "cnx.lastTeamID") == "team-1")
        #expect(defaults.string(forKey: "some.sdk.key") == "kept")
    }

    @Test func itRunsOnceThenNeverAgain() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = FakeKeychain(Self.classicItems)
        #expect(ClassicLeftovers.cleanUpIfDue(bundleIdentifier: "com.cmux.app", defaults: defaults,
                                              domain: name, keychain: keychain).ran)

        // Something classic-named appears later (it never should): the cleanup is done and leaves it.
        let late = FakeKeychain([("com.cmuxterm.app.auth.com.cmux.app", "cmux-auth-access-token")])
        let second = ClassicLeftovers.cleanUpIfDue(bundleIdentifier: "com.cmux.app", defaults: defaults,
                                                   domain: name, keychain: late)
        #expect(!second.ran)
        #expect(late.all.count == 1)
    }

    @Test func aLockedKeychainDefersTheWholeCleanupToTheNextLaunch() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "auth_has_tokens")
        let keychain = FakeKeychain(Self.classicItems)
        keychain.readable = false

        let locked = ClassicLeftovers.cleanUpIfDue(bundleIdentifier: "com.cmux.app", defaults: defaults,
                                                   domain: name, keychain: keychain)
        #expect(!locked.ran)
        #expect(keychain.all.count == Self.classicItems.count)
        #expect(defaults.bool(forKey: "auth_has_tokens"))
        #expect(defaults.object(forKey: classicCleanupMarkerKey()) == nil)

        keychain.readable = true
        let unlocked = ClassicLeftovers.cleanUpIfDue(bundleIdentifier: "com.cmux.app", defaults: defaults,
                                                     domain: name, keychain: keychain)
        #expect(unlocked.ran)
        #expect(keychain.all.isEmpty)
        #expect(defaults.object(forKey: "auth_has_tokens") == nil)
    }

    @Test func aFailedKeychainDeleteRunsTheCleanupAgainNextLaunch() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = FakeKeychain(Self.classicItems)
        keychain.failingServices = ["dev.cmux.ssh.keys"]

        let first = ClassicLeftovers.cleanUpIfDue(bundleIdentifier: "com.cmux.app", defaults: defaults,
                                                  domain: name, keychain: keychain)
        #expect(!first.ran)
        #expect(first.keychainFailed == 1)
        #expect(keychain.has("dev.cmux.ssh.keys"))
        #expect(defaults.object(forKey: classicCleanupMarkerKey()) == nil)

        keychain.failingServices = []
        let second = ClassicLeftovers.cleanUpIfDue(bundleIdentifier: "com.cmux.app", defaults: defaults,
                                                   domain: name, keychain: keychain)
        #expect(second.ran)
        #expect(keychain.all.isEmpty)
        #expect(defaults.object(forKey: classicCleanupMarkerKey()) != nil)
    }

    @Test func nextSettingsUnderCmuxStay() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let next = ["cmux.chat.display.v1", "cmux.chief.chatColors.v1", "cmux.chief.textZoom.v1",
                    "cmux.screenSharing.defaults", "cmux.screenSharing.scope",
                    "cmux.conversation.autoTranslate.c39c6f72", "cmux.conversation.textFontSize",
                    "cmux.mobile.debug.forceRebuildKeyboardDock.v1"]
        for key in next { defaults.set("kept", forKey: key) }
        defaults.set("x", forKey: "cmux.notifications.deviceTokenHex")

        let outcome = ClassicLeftovers.cleanUpIfDue(bundleIdentifier: "com.cmux.app", defaults: defaults,
                                                    domain: name, keychain: FakeKeychain([]))
        #expect(outcome.ran)
        #expect(outcome.defaultsDeleted == 1)
        for key in next { #expect(defaults.string(forKey: key) == "kept", "\(key)") }
        #expect(defaults.object(forKey: "cmux.notifications.deviceTokenHex") == nil)
    }

    @Test func aMalformedMarkerRunsTheCleanup() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("not a number", forKey: classicCleanupMarkerKey())
        let keychain = FakeKeychain(Self.classicItems)
        #expect(ClassicLeftovers.cleanUpIfDue(bundleIdentifier: "com.cmux.app", defaults: defaults,
                                              domain: name, keychain: keychain).ran)
        #expect(keychain.all.isEmpty)
    }

    /// Keychain attributes come back as strings, as data, or as something else entirely.
    @Test func keychainAttributesDecodeOrCountAsMissing() {
        #expect(ClassicLeftovers.SystemKeychain.text("svc") == "svc")
        #expect(ClassicLeftovers.SystemKeychain.text(Data("svc".utf8)) == "svc")
        #expect(ClassicLeftovers.SystemKeychain.text(Data([0xFF, 0xFE])) == nil)
        #expect(ClassicLeftovers.SystemKeychain.text(42) == nil)
        #expect(ClassicLeftovers.SystemKeychain.text(nil) == nil)
    }
}
#endif
