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
    // crash-allow: every stored var is private and read or written only inside `lock.withLock`; `lock` and `copyStatus` are immutable lets.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedQueries: [[String: Any]] = []
        private var recordedInteraction: [Bool] = []
        private var stored: Data?
        private let copyStatus: OSStatus?

        /// `copyStatus`, when set, is what every read returns (an item the read is refused).
        init(copyStatus: OSStatus? = nil) { self.copyStatus = copyStatus }

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
}
