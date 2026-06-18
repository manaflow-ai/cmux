import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobilePairedMac

@Suite struct MobilePairedMacStoreTests {
    private func makeStore() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        return (store, directory)
    }

    @Test func persistsActiveMacsScopedByStackUser() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.1", port: 8443)
        )

        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [route],
            markActive: true,
            stackUserID: "user-1",
            now: Date()
        )
        try await store.upsert(
            macDeviceID: "mac-b",
            displayName: "Mac B",
            routes: [route],
            markActive: true,
            stackUserID: "user-2",
            now: Date()
        )

        let activeUser1 = try await store.activeMac(stackUserID: "user-1")
        let activeUser2 = try await store.activeMac(stackUserID: "user-2")
        #expect(activeUser1?.macDeviceID == "mac-a")
        #expect(activeUser2?.macDeviceID == "mac-b")
        #expect(activeUser1?.routes.first?.id == "tailscale")
    }

    @Test func markingActiveDeactivatesPreviousWithinScope() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.2", port: 8443)
        )
        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: nil,
            routes: [route],
            markActive: true,
            stackUserID: "user-1",
            now: Date()
        )
        try await store.upsert(
            macDeviceID: "mac-c",
            displayName: nil,
            routes: [route],
            markActive: true,
            stackUserID: "user-1",
            now: Date()
        )

        let all = try await store.loadAll(stackUserID: "user-1")
        let active = all.filter(\.isActive)
        #expect(active.count == 1)
        #expect(active.first?.macDeviceID == "mac-c")
    }

    @Test func setActiveScopesClearToTargetStackUser() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.3", port: 8443)
        )
        // user-1 has two macs, user-2 one; each starts active within its scope.
        try await store.upsert(macDeviceID: "mac-a1", displayName: nil, routes: [route], markActive: true, stackUserID: "user-1", now: Date())
        try await store.upsert(macDeviceID: "mac-a2", displayName: nil, routes: [route], markActive: true, stackUserID: "user-1", now: Date())
        try await store.upsert(macDeviceID: "mac-b", displayName: nil, routes: [route], markActive: true, stackUserID: "user-2", now: Date())

        // Switching user-1's active Mac must not disturb user-2's active pairing.
        try await store.setActive(macDeviceID: "mac-a1")

        let activeUser1 = try await store.loadAll(stackUserID: "user-1").filter(\.isActive)
        #expect(activeUser1.map(\.macDeviceID) == ["mac-a1"])
        #expect(try await store.activeMac(stackUserID: "user-2")?.macDeviceID == "mac-b")
    }

    @Test func removePersistsAcrossReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paired-macs.sqlite3")

        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.3", port: 8443)
        )

        do {
            let store = try MobilePairedMacStore(databaseURL: url)
            try await store.upsert(
                macDeviceID: "mac-a",
                displayName: nil,
                routes: [route],
                markActive: true,
                stackUserID: nil,
                now: Date()
            )
            try await store.remove(macDeviceID: "mac-a")
        }

        let reopened = try MobilePairedMacStore(databaseURL: url)
        let all = try await reopened.loadAll()
        #expect(all.isEmpty)
    }
}
