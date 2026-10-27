import Dispatch
import Foundation
import Testing
@testable import CmuxIrohTransport

/// The suite-backed install-state store needs only Foundation, so these run on every platform the
/// package builds for, Linux included. Run under `--sanitize=thread` as well.
@Suite
struct CmxIrohUserDefaultsInstallStateStoreTests {
    @Test
    func suiteStoreRoundTripsAcrossThreadsAndInstances() throws {
        let suiteName = "CmxIrohUserDefaultsInstallStateStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = try #require(CmxIrohUserDefaultsInstallStateStore(suiteName: suiteName))

        DispatchQueue.concurrentPerform(iterations: 64) { index in
            store.set("value-\(index)", forKey: "key-\(index)")
        }

        let reopened = try #require(CmxIrohUserDefaultsInstallStateStore(suiteName: suiteName))
        for index in 0 ..< 64 {
            #expect(reopened.string(forKey: "key-\(index)") == "value-\(index)")
        }
        #expect(defaults.string(forKey: "key-7") == "value-7")
        store.set(nil, forKey: "key-7")
        #expect(reopened.string(forKey: "key-7") == nil)
    }

    @Test
    func suiteStoreRefusesTheGlobalDomain() {
        #expect(CmxIrohUserDefaultsInstallStateStore(suiteName: "NSGlobalDomain") == nil)
        #expect(CmxIrohUserDefaultsInstallStateStore(suiteName: UserDefaults.globalDomain) == nil)
    }
}
