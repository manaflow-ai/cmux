@testable import CmuxDeviceHub
import Foundation
import Testing
import os

@Suite struct DeviceCaptureNamespaceTests {
    @Test func unreadableStoreIsNeverEmpty() {
        let namespace = DeviceCaptureNamespace(accounts: { protected in
            if protected { throw CocoaError(.fileReadNoPermission) }; return []
        }, delete: { _, _ in Issue.record("inspection must not delete"); return false })
        #expect(throws: (any Error).self) { try namespace.isEmpty() }
    }

    @Test func unknownAccountPreventsEveryDeletion() {
        let namespace = DeviceCaptureNamespace(accounts: { $0 ? ["unknown-owner"] : ["device-id"] },
            delete: { _, _ in Issue.record("unknown namespace must not delete any account"); return true })
        #expect(throws: (any Error).self) { try namespace.remove() }
    }

    @Test func cleanupCountsBothStoresAndVerifiesAbsence() throws {
        let items = OSAllocatedUnfairLock(initialState: [false: ["device-id", "device-signing-key", "relay-old"], true: ["relay-current"]])
        let namespace = DeviceCaptureNamespace(accounts: { protected in items.withLock { $0[protected] ?? [] } },
            delete: { protected, account in
                items.withLock { store in
                    guard let index = store[protected]?.firstIndex(of: account) else { return false }
                    store[protected]?.remove(at: index); return true
                }
            })
        #expect(try !namespace.isEmpty())
        #expect(try namespace.remove() == .init(identities: 2, relays: 2))
        #expect(try namespace.isEmpty())
        #expect(try namespace.remove() == .init(identities: 0, relays: 0))
    }

    @Test func deletionThatLeavesAnItemCannotProduceAbsence() {
        let namespace = DeviceCaptureNamespace(accounts: { $0 ? [] : ["device-id"] }, delete: { _, _ in true })
        #expect(throws: (any Error).self) { try namespace.remove() }
    }
}
