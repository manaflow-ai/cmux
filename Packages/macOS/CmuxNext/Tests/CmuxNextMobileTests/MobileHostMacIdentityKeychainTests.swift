import CmuxNextCompat
import Foundation
import LocalAuthentication
import Security
import Testing
@testable import CmuxNextMobile

/// The Mac's identity key in the Keychain never shows UI. Leo, 2026-10-31, on a rebuilt DEV app:
/// "cmux DEV cloud-firstsend wants to use your confidential information stored in 'cmux iPhone host
/// identity' in your keychain."
@Suite struct MobileHostMacIdentityKeychainTests {
    /// What each Keychain call saw: its query and whether Keychain UI was on during it.
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var queries: [[String: Any]] = []
        var interactionDuringCalls: [Bool] = []
        var stored: Data?
        var copyStatus: OSStatus?

        func record(_ query: [String: Any]) {
            lock.withLock {
                queries.append(query)
                interactionDuringCalls.append(LoginKeychain.userInteractionAllowed)
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
        let dev = MobileHostMacIdentityStore(bundleID: "com.cmuxterm.app.debug.cloud.firstsend", stateDirectory: scratch())
        let nightly = MobileHostMacIdentityStore(bundleID: "com.cmuxterm.app.nightly", stateDirectory: scratch())
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
        let store = MobileHostMacIdentityStore(bundleID: "test.bundle", stateDirectory: directory, keychain: recorder.calls)
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
        let recorder = Recorder()
        recorder.copyStatus = errSecInteractionNotAllowed
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileHostMacIdentityStore(bundleID: "test.bundle", stateDirectory: directory, keychain: recorder.calls)
        let first = try store.loadOrCreate()
        #expect(FileManager.default.fileExists(atPath: store.fallbackFile.path))
        #expect(try store.loadOrCreate() == first)
        #expect(recorder.interactionDuringCalls.allSatisfy { !$0 })
    }
}
