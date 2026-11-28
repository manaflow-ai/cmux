#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
import Foundation
import Testing
@testable import CmuxMobileTransport

@MainActor
@Suite struct AttachmentUploadClientTests {
    private func update(_ id: String, stage: UploadStage, displayed: UInt64 = 0, confirmed: UInt64 = 0) -> UploadProgress {
        UploadProgress(uploadId: id, stage: stage, ackedBytes: displayed, confirmedBytes: confirmed,
                       sentBytes: displayed, totalBytes: 1_000, attempt: 1, macPath: nil,
                       errorCode: nil, errorMessage: nil)
    }

    @Test func onlyConfirmedNetworkProgressReportsItsDestination() {
        let client = AttachmentUploadClient()
        let owner = NSObject()
        var advanced: [String] = []
        UploadActivity.listen(owner) { advanced.append($0) }
        defer { UploadActivity.stopListening(owner) }
        let a = client.reserve(name: "a", to: .init(macID: "mac-a", cwd: nil))
        let b = client.reserve(name: "b", to: .init(macID: "mac-b", cwd: nil))
        defer { for id in [a, b] { client.cancel(id); client.forget(id) } }
        client.apply(update(a, stage: .compressing, displayed: 500))
        client.apply(update(a, stage: .uploading, displayed: 600))
        #expect(advanced.isEmpty)
        client.apply(update(a, stage: .uploading, displayed: 600, confirmed: 500))
        #expect(advanced == ["mac-a"])
        client.apply(update(a, stage: .uploading, displayed: 400, confirmed: 400))
        client.apply(update(a, stage: .uploading, displayed: 600, confirmed: 500))
        #expect(advanced == ["mac-a"], "out-of-order callbacks cannot fabricate network progress")
        #expect(client.progress[a]?.confirmedBytes == 500)
        client.apply(update(b, stage: .uploading, displayed: 300, confirmed: 300))
        #expect(advanced == ["mac-a", "mac-b"])
    }

    @Test func lateCallbacksCannotUndoCompletionOrRecreateForgottenUploads() {
        let client = AttachmentUploadClient()
        let id = client.reserve(name: "a", to: .init(macID: "mac-a", cwd: nil))
        client.apply(update(id, stage: .done, displayed: 1_000, confirmed: 1_000))
        client.apply(update(id, stage: .uploading, displayed: 500, confirmed: 500))
        #expect(client.progress[id]?.stage == .done)
        client.cancel(id)
        client.forget(id)
        client.apply(update(id, stage: .done, displayed: 1_000, confirmed: 1_000))
        #expect(client.progress[id] == nil)
    }

    @Test(arguments: [false, true])
    func lateFilesAfterCancelAreReleasedWithoutTouchingSiblingFiles(forget: Bool) throws {
        let client = AttachmentUploadClient()
        let id = client.reserve(name: "export", to: .init(macID: "mac-a", cwd: nil))
        client.cancel(id)
        if forget { client.forget(id) }
        defer { client.forget(id) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("export.mov")
        let sibling = folder.appendingPathComponent("other.mov")
        let picked = folder.appendingPathComponent("picked.mov")
        for url in [output, sibling, picked] { try Data([1]).write(to: url) }
        client.fileReady(id, url: output, ownsFile: true)
        client.fileReady(id, url: picked)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: sibling.path))
        #expect(FileManager.default.fileExists(atPath: picked.path))
    }

    @Test func lateDataAfterForgetDoesNotCreateAnOutboxFile() throws {
        let client = AttachmentUploadClient()
        let id = client.reserve(name: "export", to: .init(macID: "mac-a", cwd: nil))
        client.cancel(id)
        client.forget(id)
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
        let folder = caches.appendingPathComponent("attachment-outbox").appendingPathComponent(id)
        client.fileReady(id, data: Data([1]), name: "late.jpg")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

}
#endif
