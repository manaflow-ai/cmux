import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobilePairedMac

@Suite struct MobilePairedMacStoreIrohPinTests {
    @Test func irohEndpointPinPersistsAndSurvivesRouteRefresh() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try CmxAttachRoute(
            id: "iroh-a",
            kind: .iroh,
            endpoint: .peer(id: "endpoint-a", relayHint: nil, directAddrs: [], relayURL: nil)
        )
        let changed = try CmxAttachRoute(
            id: "iroh-b",
            kind: .iroh,
            endpoint: .peer(id: "endpoint-b", relayHint: nil, directAddrs: [], relayURL: nil)
        )

        try await store.upsert(macDeviceID: "mac-iroh", displayName: "Iroh Mac", routes: [first], markActive: true, stackUserID: "user-1", now: Date())
        try await store.upsert(macDeviceID: "mac-iroh", displayName: "Iroh Mac", routes: [changed], markActive: true, stackUserID: "user-1", now: Date())

        let mac = try #require(await store.activeMac(stackUserID: "user-1"))
        #expect(mac.irohEndpointID == "endpoint-a")
        #expect(mac.routes.map(\.id) == ["iroh-b"])
    }

    private func makeStore() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MobilePairedMacStore(databaseURL: directory.appendingPathComponent("paired-macs.sqlite3"))
        return (store, directory)
    }
}
