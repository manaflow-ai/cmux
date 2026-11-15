import CmuxInstallAuthCore
@testable import CmuxNextCloud
import CryptoKit
import Foundation
import Security
import Testing

/// A signed-in Mac stays signed in across an update (probe cloud-signed-in-after-update-production, cmux24,
/// 2026-11-15T04:06Z and 04:49Z): the install key's blob is a login Keychain item, which another build of the
/// same bundle id may read but not delete (SecItemDelete answered errSecInvalidOwnerEdit, -25244). The key's
/// rotation then failed, the next sign-in registered the retired key, its owner refused it, and every mint failed
/// while the app read signed in.
@Suite struct InstallKeyAcrossBuildsTests {
    /// The login Keychain as builds see it: every build reads every item; only the build that made one deletes it.
    actor Keychain {
        private(set) var items: [String: (data: Data, build: String)] = [:]
        func add(_ account: String, _ data: Data, build: String) throws {
            guard items[account] == nil else { throw EnclaveInstallSigner.Failure.keychain(errSecDuplicateItem) }
            items[account] = (data, build)
        }
        func delete(_ account: String, build: String) -> OSStatus {
            guard let item = items[account] else { return errSecItemNotFound }
            guard item.build == build else { return errSecInvalidOwnerEdit }
            items[account] = nil
            return errSecSuccess
        }
        func read(_ account: String) -> Data? { items[account]?.data }
        func accounts() -> [String] { Array(items.keys) }
    }

    /// One build's view of ``Keychain``.
    struct BuildKeychain: InstallKeyKeychain {
        let keychain: Keychain
        let build: String
        func accounts() async throws -> [String] { await keychain.accounts() }
        func read(_ account: String) async throws -> Data? { await keychain.read(account) }
        func add(_ account: String, _ data: Data) async throws { try await keychain.add(account, data, build: build) }
        func delete(_ account: String) async throws -> OSStatus { await keychain.delete(account, build: build) }
    }

    /// A software P-256 key as its raw bytes (the app keeps the Secure Enclave's blob).
    struct SoftwareKey: SlotKey {
        let key: P256.Signing.PrivateKey
        static func make() throws -> SoftwareKey { SoftwareKey(key: P256.Signing.PrivateKey()) }
        init(key: P256.Signing.PrivateKey) { self.key = key }
        init(blob: Data) throws { key = try P256.Signing.PrivateKey(rawRepresentation: blob) }
        var blob: Data { key.rawRepresentation }
        var publicKeyX963: Data { key.publicKey.x963Representation }
        func sign(_ message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
    }

    private func app(_ build: String, keychain: Keychain, owner: MacTeamAuthOwner, root: URL) -> MacInstallIdentity {
        MacInstallIdentity(store: .slots(SoftwareKey.self, keychain: BuildKeychain(keychain: keychain, build: build), directory: root),
                           transport: owner, deviceName: "Test Mac", clientVersion: "2.4.0")
    }

    private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func aSignedInMacStaysSignedInAfterAnUpdateAndAfterSigningOutAndInThere() async throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = Keychain(), owner = MacTeamAuthOwner(refusesKnownKeys: true)
        let before = app("4366880343301", keychain: keychain, owner: owner, root: root)
        try await before.signedIn(stackUser: "stack_1", session: { "test-session" })
        let install = await before.installID()

        // Updated in place: the new build mints with the key and install the previous one registered.
        let after = app("4367130096301", keychain: keychain, owner: owner, root: root)
        try await after.signedIn(stackUser: "stack_1", session: { "test-session" })
        #expect(try await !after.installToken().isEmpty)
        #expect(await after.installID() == install)
        #expect(await owner.registrations == 1)

        // Sign-out on the new build retires the key the previous build made, which it may not delete.
        await after.signOut(stackUser: "stack_1", session: { "test-session" })
        await after.unbind()
        try await after.signedIn(stackUser: "stack_1", session: { "test-session" })
        #expect(try await !after.installToken().isEmpty)
        #expect(await owner.registrations == 2)
        #expect(await after.installID() != install)
        // The retired item stays (this build may not delete it); the key is the generation above it.
        #expect(Set(await keychain.accounts()).count == 2)
    }

    /// The call site over Rust's `cloud_identity_install_key_slots` (its own cases: cmux-cloud-config
    /// `install_key_slots_tests`): the Keychain I/O lands where Rust says.
    @Test func aRotationMovesAboveEveryItemItCouldNotDelete() async throws {
        let keychain = Keychain(), account = "install-key-0123456789abcdef"
        let old = SlotInstallSigner<SoftwareKey>(account: account, keychain: BuildKeychain(keychain: keychain, build: "old"))
        let new = SlotInstallSigner<SoftwareKey>(account: account, keychain: BuildKeychain(keychain: keychain, build: "new"))
        let first = try await old.publicKeyX963()
        #expect(try await new.publicKeyX963() == first)
        #expect(await keychain.accounts() == [account])

        try await new.rotate()
        let second = try await new.publicKeyX963()
        #expect(second != first)
        #expect(try await old.publicKeyX963() == second)
        #expect(Set(await keychain.accounts()) == [account, "\(account).2"])

        // Its own generation goes; the kept one stays below the new key.
        try await new.rotate()
        let third = try await new.publicKeyX963()
        #expect(third != second && third != first)
        #expect(Set(await keychain.accounts()) == [account, "\(account).2"])

        // A build that may delete everything leaves no key: the next use makes one at the account itself.
        let solo = Keychain()
        let mine = SlotInstallSigner<SoftwareKey>(account: account, keychain: BuildKeychain(keychain: solo, build: "solo"))
        _ = try await mine.publicKeyX963()
        try await mine.rotate()
        #expect(await solo.accounts().isEmpty)
        _ = try await mine.publicKeyX963()
        #expect(await solo.accounts() == [account])

        // Another user's key and look-alike accounts are never the key.
        try await keychain.add("install-key-ffffffffffffffff", Data(), build: "old")
        try await keychain.add("\(account).02", Data(), build: "old")
        #expect(try await new.publicKeyX963() == third)
    }

    /// Leo's NIGHTLY: a relaunch's first Cloud call came before the restored session bound the install, and the
    /// machine list answered `install token mint failed: signedOut`.
    @Test func theFirstCallOfALaunchWaitsForTheRestoredSessionsBind() async throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = MacInstallIdentity(store: .files(directory: root), transport: MacTeamAuthOwner(), deviceName: "Test Mac",
                                          clientVersion: "2.4.0")
        let early = Task { try await identity.installToken(awaitingBind: .seconds(30)) }
        while await identity.pendingBindWaiters == 0 { await Task.yield() }
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        #expect(try await !early.value.isEmpty)

        // No bind comes (signed out): the wait ends at its deadline, signed out.
        await identity.unbind()
        await #expect(throws: MacInstallIdentity.Failure.signedOut) { try await identity.installToken(awaitingBind: .milliseconds(20)) }
    }

    @Test func aKeychainRefusalNamesItselfNotABadReply() async throws {
        let failure = CloudAccessToken.failure(EnclaveInstallSigner.Failure.keychain(errSecInvalidOwnerEdit))
        #expect(failure.code == "local_failure")
        #expect(failure.detail?.hasPrefix("keychain(-25244") == true)
        #expect(CloudAccessToken.failure(CancellationError()) == .local("cancelled"))
    }
}
