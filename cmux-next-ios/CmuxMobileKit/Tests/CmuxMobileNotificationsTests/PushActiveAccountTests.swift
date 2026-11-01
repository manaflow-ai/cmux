import CryptoKit
import Foundation
import Testing
import UserNotifications
@testable import CmuxMobileNotifications

/// A paired phone keeps its decryption key at logout. Only the account with
/// an active session may turn a queued APNs payload into a readable notice.
@Suite struct PushActiveAccountTests {
    @Test func markerIsSeparateFromPairingAndChangesWithTheSession() throws {
        let keys = PushKeys(store: PushMemoryStore(), enclave: false)
        keys.trust(mac: "mac-a", identityKey: "04aa", boxKey: nil, user: "account-a", phone: "phone-a")
        let marker = PushActiveAccount(store: keys.store)
        #expect(!marker.permits(keys.trust()))

        try marker.update(userID: "account-a")
        #expect(marker.userID() == "account-a")
        #expect(marker.permits(keys.trust()))

        try marker.update(userID: nil)
        #expect(marker.userID() == nil)
        #expect(!marker.permits(keys.trust()))
        // Logout keeps the approval/decryption identity for a later sign-in.
        #expect(keys.trust()?.user == "account-a")

        try marker.update(userID: "account-b")
        #expect(!marker.permits(keys.trust()))
        try marker.update(userID: "account-a")
        #expect(marker.permits(keys.trust()))
    }

    /// A signed-in phone that never paired with a sealing Mac has no trust
    /// record: its unsealed notifications keep working, and still stop at logout.
    @Test func signedInWithoutPairingStillPermitsUnsealedPushes() throws {
        let keys = PushKeys(store: PushMemoryStore(), enclave: false)
        let marker = PushActiveAccount(store: keys.store)
        #expect(!marker.permits(nil))
        try marker.update(userID: "u1")
        #expect(marker.permits(nil))
        let content = UNMutableNotificationContent()
        content.title = "Claude asks"
        content.userInfo = SealedPushTests.question.userInfo
        #expect(ServicePush().withheld(content, keys: keys) == nil)
        try marker.update(userID: nil)
        #expect(ServicePush().withheld(content, keys: keys)?.userInfo.isEmpty == true)
    }

    /// No shared keychain (a build signed without one): nothing is retained
    /// to withhold, so behavior is unchanged.
    @Test func noKeychainKeepsTheUnsealedPath() {
        let content = UNMutableNotificationContent()
        content.userInfo = SealedPushTests.question.userInfo
        #expect(ServicePush().withheld(content, keys: nil) == nil)
    }

    /// A Keychain write failure must be visible to the sign-out owner; the
    /// old marker is still authorized until the owner handles revocation.
    private struct RejectingSecrets: PushSecretStore {
        struct Failed: Error {}
        func read(_ account: String) throws -> Data? { Data("u1".utf8) }
        func write(_ data: Data, account: String) throws { throw Failed() }
        func delete(_ account: String) {}
    }

    @Test func failedMarkerClearIsReported() {
        let marker = PushActiveAccount(store: RejectingSecrets())
        #expect(marker.userID() == "u1")
        #expect(throws: RejectingSecrets.Failed.self) { try marker.update(userID: nil) }
        #expect(marker.userID() == "u1")
    }

    @Test func queuedSealedPushIsGenericUntilTheCorrectAccountSignsIn() throws {
        let (keys, macKey, publicKey) = try SealedPushTests.setUp()
        let raw = try SealedPushTests.sealedPush(macKey: macKey, pushKey: publicKey, payload: SealedPushTests.question)
        let content = UNMutableNotificationContent()
        content.title = "cmux"
        content.body = "New notification from Mac mini"
        content.userInfo = raw
        let service = ServicePush()
        let marker = PushActiveAccount(store: keys.store)

        #expect(service.opened(content, keys: keys) == nil)
        let signedOut = try #require(service.withheld(content, keys: keys))
        #expect(signedOut.title == "cmux" && signedOut.categoryIdentifier == PushCategory.sealed.rawValue)
        #expect(signedOut.userInfo.isEmpty)
        #expect(signedOut.body.contains("New notification"))

        try marker.update(userID: "u1")
        #expect(service.withheld(content, keys: keys) == nil)
        let authorized = try #require(service.opened(content, keys: keys))
        #expect(authorized.title == "Claude asks")
        #expect(authorized.body == "Which branch?")

        try marker.update(userID: "u2")
        #expect(service.opened(content, keys: keys) == nil)
        #expect(service.withheld(content, keys: keys)?.userInfo.isEmpty == true)
        try marker.update(userID: nil)
        #expect(service.opened(content, keys: keys) == nil)
    }

    @Test func legacyPlaintextPushIsAlsoWithheldAfterLogout() throws {
        let keys = PushKeys(store: PushMemoryStore(), enclave: false)
        keys.trust(mac: "mac-1", identityKey: "04aa", boxKey: nil, user: "u1", phone: "p1")
        let marker = PushActiveAccount(store: keys.store)
        let content = UNMutableNotificationContent()
        content.title = "Secret approval"
        content.body = "read private file"
        content.userInfo = SealedPushTests.question.userInfo
        let service = ServicePush()

        #expect(service.withheld(content, keys: keys)?.userInfo.isEmpty == true)
        try marker.update(userID: "u1")
        #expect(service.withheld(content, keys: keys) == nil)
        try marker.update(userID: "u2")
        #expect(service.withheld(content, keys: keys)?.body.contains("private file") == false)
    }

    @Test func aStaleAccountCannotUseEvenAPlaintextAction() {
        let payload = SealedPushTests.question
        let gate = PushTrustGate(trust: nil, keys: nil, authorized: false)
        #expect(gate.verdict(userInfo: payload.userInfo, shown: nil) == .refused)
    }

    @Test @MainActor func mirrorSerializesRestoredAndSignedOutAccounts() async {
        let marker = PushActiveAccount(store: PushMemoryStore())
        let mirror = PushActiveAccountMirror(account: marker)
        await mirror.update(userID: "u1").value
        #expect(marker.userID() == "u1")
        await mirror.clearBeforeSignOut()
        #expect(marker.userID() == nil)
        await mirror.update(userID: "u2").value
        #expect(marker.userID() == "u2")
    }
}
