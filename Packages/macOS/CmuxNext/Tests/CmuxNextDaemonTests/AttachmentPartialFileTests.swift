import Foundation
import Testing
@testable import CmuxNextDaemon

/// p02-threads-053 (plans/cmux-next/chrome-parity/p02-threads.md, maybe-main-blocking): an attachment read's disk
/// steps, which `AttachmentTransfer.download` runs on the app's files lane. The bytes land in a hidden partial file
/// beside the destination and move into place only when complete, so a failed read leaves nothing.
@Suite struct AttachmentPartialFileTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "attachment-partial-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func chunksWrittenAtTheirOffsetsLandAtTheDestinationWhole() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "cache/abc-original.png")
        let partial = try AttachmentPartialFile.create(for: destination)
        #expect(partial.url.deletingLastPathComponent() == destination.deletingLastPathComponent())
        #expect(partial.url.lastPathComponent.hasPrefix(".abc-original.png."))

        try partial.write(Data("hello ".utf8), at: 0)
        try partial.write(Data("world".utf8), at: 6)
        try partial.finish()

        #expect(try Data(contentsOf: destination) == Data("hello world".utf8))
        #expect(!FileManager.default.fileExists(atPath: partial.url.path))
    }

    @Test func aDiscardedReadLeavesNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "abc-poster.jpg")
        let partial = try AttachmentPartialFile.create(for: destination)
        try partial.write(Data("half".utf8), at: 0)
        partial.discard()

        #expect(!FileManager.default.fileExists(atPath: partial.url.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func aConcurrentReadThatPlacedTheFileFirstWins() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "abc-preview.mp4")
        let first = try AttachmentPartialFile.create(for: destination)
        let second = try AttachmentPartialFile.create(for: destination)
        try first.write(Data("same".utf8), at: 0)
        try second.write(Data("same".utf8), at: 0)
        try first.finish()

        try second.finish()

        #expect(try Data(contentsOf: destination) == Data("same".utf8))
        #expect(!FileManager.default.fileExists(atPath: second.url.path))
    }
}
