import CmuxHomeCore
@testable import CmuxNextHome
import Foundation
import Testing

/// Opening New Message builds a store over Home's own attachment folder (the app's Caches
/// `cmux-home-blobs`, the folder Home's store keeps its drafts' and pending sends' blobs in).
/// That store keeps no blobs, so its start must not prune the folder: a draft's picture unchanged
/// for 10 days stays. A store that prunes there (the default) deletes it at its start; the control
/// shows that, so this test waits long enough for New Message's store to have deleted it.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HomeNewMessageBlobsTests {
    @Test func openingNewMessageKeepsHomesDraftAttachments() async throws {
        let (folder, draftBlob) = try Self.folderWithOldBlob()
        let control = try Self.folderWithOldBlob()
        let me = Participant(id: ParticipantID("me"), kind: .human, displayName: "")
        let source = HomeNewMessageComposerSource(me: me) { _ in throw HomeRejection.invalid("test.no_send") }

        let newMessage = source.store(blobs: folder)
        newMessage.start()
        defer { newMessage.stop() }
        let pruning = HomeStore(source: source, blobCacheDirectory: control.0)
        pruning.start()
        defer { pruning.stop() }

        let fm = FileManager.default
        for _ in 0..<200_000 where fm.fileExists(atPath: control.1.path) { await Task.yield() }
        try #require(!fm.fileExists(atPath: control.1.path), "the control store never pruned: the wait proves nothing")
        #expect(fm.fileExists(atPath: draftBlob.path), "opening New Message deleted a blob Home's draft keeps")
    }

    /// A new folder holding one blob folder last changed 10 days ago (past the prune's 7 days).
    static func folderWithOldBlob() throws -> (URL, URL) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("cmux-nm-blobs-\(UUID().uuidString)", isDirectory: true)
        let blob = folder.appendingPathComponent("draft-picture", isDirectory: true)
        try fm.createDirectory(at: blob, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: blob.appendingPathComponent("blob"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86_400)], ofItemAtPath: blob.path)
        return (folder, blob)
    }
}
