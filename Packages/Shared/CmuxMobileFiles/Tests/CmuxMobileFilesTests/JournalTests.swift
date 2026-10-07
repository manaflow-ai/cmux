import CmuxMobileFiles
import CmuxMobileWire
import Foundation
import Testing

@Suite("Transfer journal")
struct JournalTests {
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
