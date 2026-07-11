import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@Suite struct PairedMacInstanceTagBackupTests {
    private func makeInnerStore() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        return (store, directory)
    }

    private func route() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "manual",
            kind: .tailscale,
            endpoint: .hostPort(host: "10.0.0.1", port: 22)
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

    private func encodedRecordObject(from op: PairedMacBackupOp) throws -> [String: Any] {
        let body = PairedMacBackupRequestBody(ops: [PairedMacBackupOpWire(op: op)])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        let ops = try #require(json?["ops"] as? [[String: Any]])
        return try #require(ops.first?["record"] as? [String: Any])
    }

    @Test func upsertForwardsAndUploadsInstanceTag() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = FakeBackup()
        let store = BackingUpPairedMacStore(inner: inner, backup: backup)

        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Studio",
            routes: [try route()],
            instanceTag: "feature-a",
            markActive: true,
            stackUserID: "user-1",
            now: Date()
        )

        #expect(try await inner.loadAll(stackUserID: "user-1").first?.instanceTag == "feature-a")
        let uploaded = await backup.uploadedOps().first.flatMap(uploadedRecord(from:))
        #expect(uploaded?.instanceTag == "feature-a")
    }

    @Test func restoreAppliesInstanceTagFromBackup() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = FakeBackup(records: [
            PairedMacBackupRecord(
                macDeviceID: "mac-a",
                displayName: "Studio",
                routes: [try route()],
                createdAt: 1_000,
                lastSeenAt: 2_000,
                isActive: true,
                instanceTag: "feature-a"
            ),
        ])

        _ = await PairedMacRestore(store: inner, backup: backup).run(accountID: "user-1")

        #expect(try await inner.loadAll(stackUserID: "user-1").first?.instanceTag == "feature-a")
    }

    @Test func recordWireEncodesInstanceTagAndDecodesLegacyPayload() throws {
        let untagged = PairedMacBackupRecord(
            macDeviceID: "mac-a",
            displayName: "Studio",
            routes: [],
            createdAt: 1,
            lastSeenAt: 2,
            isActive: true
        )
        let untaggedJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(untagged)
        ) as? [String: Any]
        #expect(untaggedJSON?.keys.contains("instanceTag") == true)
        #expect(untaggedJSON?["instanceTag"] is NSNull)

        let tagged = PairedMacBackupRecord(
            macDeviceID: "mac-a",
            displayName: "Studio",
            routes: [],
            createdAt: 1,
            lastSeenAt: 2,
            isActive: true,
            instanceTag: "feature-a"
        )
        let decoded = try JSONDecoder().decode(
            PairedMacBackupRecord.self,
            from: JSONEncoder().encode(tagged)
        )
        #expect(decoded.instanceTag == "feature-a")

        let legacyJSON = Data(
            #"{"macDeviceID":"mac-a","routes":[],"createdAt":1,"lastSeenAt":2,"isActive":true}"#.utf8
        )
        let legacy = try JSONDecoder().decode(PairedMacBackupRecord.self, from: legacyJSON)
        #expect(legacy.instanceTag == nil)
    }

    @Test func routineMirrorIncludesExplicitNullInstanceTag() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = FakeBackup()
        let store = BackingUpPairedMacStore(inner: inner, backup: backup)

        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Studio",
            routes: [try route()],
            markActive: true,
            stackUserID: "user-1",
            now: Date()
        )

        let first = try #require(await backup.uploadedOps().first)
        let keys = try encodedRecordObject(from: first)
        #expect(keys.keys.contains("instanceTag"))
        #expect(keys["instanceTag"] is NSNull)
    }
}
