import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@Suite struct PairedMacIrohPinBackupTests {
    private func makeInnerStore() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        return (store, directory)
    }

    private func irohRoute(_ endpointID: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(id: endpointID, relayHint: nil, directAddrs: [], relayURL: nil)
        )
    }

    private func uploadedRecord(from op: PairedMacBackupOp) -> PairedMacBackupRecord? {
        switch op {
        case .upsert(let record), .upsertPreservingCustomizations(let record),
             .revive(let record), .revivePreservingCustomizations(let record):
            return record
        case .delete:
            return nil
        }
    }

    @Test func localIrohPinIsNotBackedUpOrRestored() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = FakeBackup()
        let store = BackingUpPairedMacStore(inner: inner, backup: backup)

        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [try irohRoute("endpoint-a")],
            markActive: true,
            stackUserID: "user-1",
            now: Date()
        )
        let uploadedBeforePin = await backup.uploadedOps()
        try await store.setPinnedIrohEndpointID(
            macDeviceID: "mac-a",
            endpointID: "endpoint-a",
            stackUserID: "user-1",
            teamID: nil,
            now: Date()
        )
        #expect(await backup.uploadedOps().count == uploadedBeforePin.count)
        #expect(try await inner.loadAll(stackUserID: "user-1").first?.pinnedIrohEndpointID == "endpoint-a")

        let record = try #require(uploadedBeforePin.first.flatMap(uploadedRecord(from:)))
        let (freshInner, freshDir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: freshDir) }
        let restoredStore = BackingUpPairedMacStore(
            inner: freshInner,
            backup: FakeBackup(records: [record])
        )
        let restored = try await restoredStore.loadAll(stackUserID: "user-1")
        #expect(restored.first?.pinnedIrohEndpointID == nil)
    }
}
