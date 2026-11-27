import CmuxNextCompat
import Foundation
import LocalAuthentication
import Security
import Testing
@testable import CmuxNextMobile

/// The guard of the Keychain UI switch these tests share, as the app shares its one (`AppServices`):
/// the switch is the process's, so two instances overlapping in parallel tests would restore it early.
nonisolated let testLoginKeychain = LoginKeychain()

/// The Mac's identity key in the Keychain never shows UI. Leo, 2026-10-31, on a rebuilt DEV app:
/// "cmux DEV cloud-firstsend wants to use your confidential information stored in 'cmux iPhone host
/// identity' in your keychain."
@Suite struct MobileHostMacIdentityKeychainTests {
    /// What each Keychain call saw: its query and whether Keychain UI was on during it.
    // crash-allow: every stored var is private and read or written only inside `lock.withLock`; `lock` is an immutable let.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedQueries: [[String: Any]] = []
        private var recordedInteraction: [Bool] = []
        private var stored: Data?
        private var copyStatus: OSStatus?

        /// `copyStatus`, when set, is what every read returns (an item the read is refused).
        init(copyStatus: OSStatus? = nil) { self.copyStatus = copyStatus }

        /// From now on every read returns `status` (nil: the reads answer again).
        func refuseReads(_ status: OSStatus?) { lock.withLock { copyStatus = status } }

        var queries: [[String: Any]] { lock.withLock { recordedQueries } }
        var interactionDuringCalls: [Bool] { lock.withLock { recordedInteraction } }

        func record(_ query: [String: Any]) {
            lock.withLock {
                recordedQueries.append(query)
                recordedInteraction.append(LoginKeychain.userInteractionAllowed)
            }
        }

        var calls: MobileHostSecItems {
            MobileHostSecItems(
                copy: { [self] query in
                    record(query)
                    return lock.withLock {
                        if let copyStatus { return (copyStatus, nil) }
                        return (stored == nil ? errSecItemNotFound : errSecSuccess, stored)
                    }
                },
                update: { [self] query, _ in record(query); return errSecUnimplemented },
                add: { [self] query in
                    record(query)
                    return lock.withLock {
                        if stored != nil || copyStatus != nil { return errSecDuplicateItem }
                        stored = query[kSecValueData as String] as? Data
                        return errSecSuccess
                    }
                },
                delete: { [self] query in record(query); return errSecUnimplemented })
        }
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MobileHostMacIdentityKeychainTests-\(UUID().uuidString)")
    }

    @Test func theItemIsThisBundleIDsAlone() {
        let dev = MobileHostMacIdentityStore(bundleID: "com.cmuxterm.app.debug.cloud.firstsend", stateDirectory: scratch(), loginKeychain: testLoginKeychain)
        let nightly = MobileHostMacIdentityStore(bundleID: "com.cmuxterm.app.nightly", stateDirectory: scratch(), loginKeychain: testLoginKeychain)
        #expect(dev.service == "com.cmuxterm.app.debug.cloud.firstsend.iphone-host.identity")
        #expect(nightly.service == "com.cmuxterm.app.nightly.iphone-host.identity")
        let query = MobileHostMacIdentityStore.readQuery(service: dev.service)
        #expect(query[kSecAttrService as String] as? String == dev.service)
        #expect(query[kSecAttrAccount as String] as? String == "identity")
    }

    @Test func theReadAndAddAskForNoUI() throws {
        for query in [MobileHostMacIdentityStore.readQuery(service: "s"),
                      MobileHostMacIdentityStore.addQuery(service: "s", privateKey: Data([1]))] {
            let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
            #expect(context.interactionNotAllowed)
        }
    }

    @Test func everyKeychainCallRunsWithKeychainUIOff() throws {
        let recorder = Recorder()
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileHostMacIdentityStore(bundleID: "test.bundle", stateDirectory: directory, keychain: recorder.calls, loginKeychain: testLoginKeychain)
        let first = try store.loadOrCreate()
        #expect(try store.loadOrCreate() == first)
        // read (not found), add, read (found)
        #expect(recorder.queries.count == 3)
        #expect(recorder.interactionDuringCalls.allSatisfy { !$0 })
        #expect(recorder.queries.allSatisfy { $0[kSecAttrService as String] as? String == "test.bundle.iphone-host.identity" })
        #expect(!FileManager.default.fileExists(atPath: store.fallbackFile.path))
    }

    /// An item an earlier build signed another way made: the read is refused (no prompt), and the
    /// store keeps a key of its own in the file, the same one every launch.
    @Test func aRefusedItemFallsBackToTheFileWithoutAsking() throws {
        let recorder = Recorder(copyStatus: errSecInteractionNotAllowed)
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileHostMacIdentityStore(bundleID: "test.bundle", stateDirectory: directory, keychain: recorder.calls, loginKeychain: testLoginKeychain)
        let first = try store.loadOrCreate()
        #expect(FileManager.default.fileExists(atPath: store.fallbackFile.path))
        #expect(try store.loadOrCreate() == first)
        #expect(recorder.interactionDuringCalls.allSatisfy { !$0 })
    }

    /// The Keychain refused one read at launch (2026-11-02, -25293) and the store made a file key, a
    /// second identity beside the Keychain's. Later launches proved whichever store answered, so the
    /// phone that pinned the Keychain key refused this Mac (`mac_identity_changed`) whenever the
    /// Keychain refused again, until a relaunch (2026-11-03). A refused read must never prove another
    /// key than the Keychain's: it waits (throws) instead of minting one.
    @Test func aKeychainThatRefusesSometimesKeepsOneIdentity() throws {
        let recorder = Recorder()
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileHostMacIdentityStore(bundleID: "test.bundle", stateDirectory: directory, keychain: recorder.calls, loginKeychain: testLoginKeychain)
        let pinned = try store.loadOrCreate(fileStoreOnRefusal: false)
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecMissingEntitlement] {
            recorder.refuseReads(status)
            #expect(throws: MobileHostMacIdentityError.keychainRefused(status)) { try store.loadOrCreate(fileStoreOnRefusal: false) }
            #expect(!FileManager.default.fileExists(atPath: store.fallbackFile.path))
            recorder.refuseReads(nil)
            #expect(try store.loadOrCreate(fileStoreOnRefusal: false) == pinned)
        }
    }

    /// A Mac already split (this nightly since 2026-11-02: a file key beside the Keychain's) heals at the
    /// next read that answers: the file key stops counting, so no later refused read proves it, and is
    /// set aside (never deleted: a phone may have pinned it while the Mac was split).
    @Test func aSecondIdentityInTheFileIsSetAsideWhenTheKeychainAnswers() throws {
        let recorder = Recorder()
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileHostMacIdentityStore(bundleID: "test.bundle", stateDirectory: directory, keychain: recorder.calls, loginKeychain: testLoginKeychain)
        let pinned = try store.loadOrCreate()
        let second = MobileHostMacIdentity.generate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try second.privateKey.write(to: store.fallbackFile)
        #expect(try store.loadOrCreate() == pinned)
        #expect(!FileManager.default.fileExists(atPath: store.fallbackFile.path))
        let aside = try Data(contentsOf: store.fallbackFile.appendingPathExtension("superseded"))
        #expect(MobileHostMacIdentity.restore(aside) == second)
        recorder.refuseReads(errSecAuthFailed)
        #expect(throws: MobileHostMacIdentityError.keychainRefused(errSecAuthFailed)) { try store.loadOrCreate(fileStoreOnRefusal: false) }
    }

    /// A Mac still split when the fixed build first runs, with the Keychain refusing: the old code (and
    /// the first fix) proved the file key, so the phone that pinned the Keychain's saw
    /// `mac_identity_changed` until the Keychain answered and a relaunch. A refused read proves no file
    /// key: it waits for the Keychain's. Only the DEV fallback after its retries uses the file.
    @Test func aRefusedReadNeverProvesTheFileKeyBesideTheKeychainItem() throws {
        let recorder = Recorder()
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileHostMacIdentityStore(bundleID: "test.bundle", stateDirectory: directory, keychain: recorder.calls, loginKeychain: testLoginKeychain)
        let pinned = try store.loadOrCreate()
        let second = MobileHostMacIdentity.generate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try second.privateKey.write(to: store.fallbackFile)
        recorder.refuseReads(errSecInteractionNotAllowed)
        #expect(throws: MobileHostMacIdentityError.keychainRefused(errSecInteractionNotAllowed)) {
            try store.loadOrCreate(fileStoreOnRefusal: false)
        }
        #expect(try store.loadOrCreate(fileStoreOnRefusal: true) == second)
        recorder.refuseReads(nil)
        #expect(try store.loadOrCreate(fileStoreOnRefusal: false) == pinned)
        #expect(!FileManager.default.fileExists(atPath: store.fallbackFile.path))
    }
}
