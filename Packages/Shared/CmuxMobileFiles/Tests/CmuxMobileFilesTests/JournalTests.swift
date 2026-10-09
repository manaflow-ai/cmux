import CmuxMobileFiles
import CmuxMobileWire
import Foundation
import Testing

@Suite("Transfer journal")
struct JournalTests {
    @Test func uploadReferencesRoundTripAndOlderEntriesRemainReadable() async throws {
        let record = TransferRecord(id: "upload", hostID: "h", direction: .upload, localPath: "/tmp/a", remotePath: "",
                                    name: "a", mime: "text/plain", status: .finished, resultPath: "/inbox/a", uploadID: "up_verified")
        let encoded = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(TransferRecord.self, from: encoded).uploadID == "up_verified")
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "uploadID")
        let decoded = try JSONDecoder().decode(TransferRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.uploadID == nil)
        #expect(decoded.resultPath == "/inbox/a")
    }

    @Test func aRunningTransferReloadsAsPaused() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("c4j-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let journal = TransferJournal(fileURL: file)
        await journal.put(TransferRecord(id: "a", hostID: "h", direction: .upload, localPath: "/tmp/a", remotePath: "",
                                         name: "a", mime: "text/plain", dest: FilesUploadDestination(kind: .composer),
                                         completedBytes: 10, status: .running))
        await journal.put(TransferRecord(id: "b", hostID: "h", direction: .download, localPath: "/tmp/b", remotePath: "~/b",
                                         name: "b", mime: "text/plain", status: .finished))
        let reloaded = TransferJournal(fileURL: file)
        #expect(await reloaded.record("a")?.status == .paused)
        #expect(await reloaded.record("a")?.completedBytes == 10)
        #expect(await reloaded.record("b")?.status == .finished)
        #expect(await reloaded.all().count == 2)
    }
}

@Suite("Transfer journal protection")
struct JournalProtectionTests {
    @Test func anUnreadableJournalIsNeverOverwritten() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("c4p-\(UUID().uuidString).json")
        defer {
            chmod(file.path, 0o600)
            try? FileManager.default.removeItem(at: file)
        }
        let first = TransferJournal(fileURL: file)
        await first.put(TransferRecord(id: "keep", hostID: "h", direction: .upload, localPath: "/tmp/k", remotePath: "",
                                       name: "k", mime: "text/plain", status: .paused))
        let before = try Data(contentsOf: file)
        chmod(file.path, 0o000) // as if the device were locked
        let locked = TransferJournal(fileURL: file)
        await locked.put(TransferRecord(id: "new", hostID: "h", direction: .upload, localPath: "/tmp/n", remotePath: "",
                                        name: "n", mime: "text/plain"))
        chmod(file.path, 0o600)
        #expect(try Data(contentsOf: file) == before)
        // Once readable, the next write merges instead of replacing.
        await locked.update("new") { $0.status = .paused }
        let merged = TransferJournal(fileURL: file)
        #expect(await merged.record("keep") != nil)
        #expect(await merged.record("new") != nil)
    }
}
