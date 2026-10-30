import CmuxHomeCore
import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// Media in Cloud DMs and groups: the Cloud source uploads and fetches
/// attachment bytes through the daemon's `cloud-attachments-v1` commands
/// instead of refusing them ("attachments unsupported").
struct CloudAttachmentTests {
    static let conversation = ConversationID("conv_media")

    private func file(_ bytes: Data) throws -> URL {
        let directory = CloudSourceHarness.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("photo.jpg")
        try bytes.write(to: url)
        return url
    }

    @Test func uploadSendsTheBytesToTheCloudConversation() async throws {
        let daemon = FakeCloudDaemon()
        let source = CloudSourceHarness.connected(to: daemon)
        let bytes = Data("a photo's bytes".utf8)
        let ref = AttachmentRef(hash: String(repeating: "a", count: 64), name: "photo.jpg", mimeType: "image/jpeg", byteCount: bytes.count,
                                width: 4, height: 3)
        let stored = try await source.upload(AttachmentUpload(conversation: Self.conversation, fileURL: try file(bytes), ref: ref))
        #expect(stored.hash == ref.hash)
        #expect(stored.byteCount == bytes.count)
        let uploads = await daemon.uploads
        #expect(uploads.count == 1)
        #expect(uploads.first?.conversation == Self.conversation.rawValue)
        #expect(uploads.first?.attachment.hash == ref.hash)
        #expect(uploads.first?.attachment.width == 4)
        #expect(uploads.first?.bytes == bytes)
    }

    @Test func fetchReadsTheOriginalOnceThenFromTheCache() async throws {
        let daemon = FakeCloudDaemon()
        let hash = String(repeating: "b", count: 64)
        let bytes = Data("the original".utf8)
        await daemon.hold(bytes, hash: hash, mimeType: "image/png")
        let cache = CloudSourceHarness.temporaryDirectory()
        let source = CloudSourceHarness.connected(to: daemon, attachmentCache: cache)
        let ref = AttachmentRef(hash: hash, name: "shot.png", mimeType: "image/png", byteCount: bytes.count)
        let location = AttachmentLocation(conversation: Self.conversation)
        let first = try await source.fetch(ref, at: location, variant: .original)
        #expect(try Data(contentsOf: first) == bytes)
        #expect(first.path.hasPrefix(cache.path), "the fetched file lands in the source's cache")
        let second = try await source.fetch(ref, at: location, variant: .original)
        #expect(second == first)
        #expect(await daemon.downloads == ["\(Self.conversation.rawValue):\(hash):original"], "a cached variant is not read again")
    }

    @Test func fetchReadsAVideosPosterVariant() async throws {
        let daemon = FakeCloudDaemon()
        let hash = String(repeating: "c", count: 64)
        let posterHash = String(repeating: "d", count: 64)
        let poster = Data("poster frame".utf8)
        await daemon.hold(poster, hash: hash, variant: .poster, mimeType: "image/jpeg")
        let source = CloudSourceHarness.connected(to: daemon)
        var ref = AttachmentRef(hash: hash, name: "clip.mov", mimeType: "video/quicktime", byteCount: 1000)
        ref.poster = AttachmentDerivedImage(hash: posterHash, mimeType: "image/jpeg", byteCount: poster.count)
        let url = try await source.fetch(ref, at: AttachmentLocation(conversation: Self.conversation), variant: .poster)
        #expect(try Data(contentsOf: url) == poster)
        #expect(await daemon.downloads == ["\(Self.conversation.rawValue):\(hash):poster"])
    }

    @Test func aPartWithoutAPosterIsRefusedWithoutARead() async throws {
        let daemon = FakeCloudDaemon()
        let source = CloudSourceHarness.connected(to: daemon)
        let ref = AttachmentRef(hash: String(repeating: "e", count: 64), name: "clip.mov", mimeType: "video/quicktime", byteCount: 10)
        await #expect(throws: HomeRejection.invalid("no_poster")) {
            _ = try await source.fetch(ref, at: AttachmentLocation(conversation: Self.conversation), variant: .poster)
        }
        #expect(await daemon.downloads.isEmpty)
    }
}
