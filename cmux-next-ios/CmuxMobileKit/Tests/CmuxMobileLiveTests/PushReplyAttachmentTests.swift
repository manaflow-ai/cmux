import CmuxMobileAgentChat
import CmuxMobileNotifications
import CmuxMobileTransport
import CryptoKit
import Foundation
import Testing
@testable import CmuxMobileLive

@MainActor
@Suite struct PushReplyAttachmentTests {
    /// Receiver retains a digest and counters, never the uploaded original.
    actor Receiver: LinkChannel {
        nonisolated let id: UInt32 = 1
        var bytes = 0
        var largestWrite = 0
        var hash = SHA256()
        var answered = false

        func send(_ data: Data) async throws {
            bytes += data.count
            largestWrite = max(largestWrite, data.count)
            hash.update(data: data)
        }

        func receive() async throws -> Data? {
            guard !answered else { return nil }
            answered = true
            return Data(#"{"path":"/uploads/original","size":\#(bytes)}"#.utf8)
        }

        func close(code: String, reason: String) async {}
        func digest() -> Data { Data(hash.finalize()) }
    }

    actor Link: MacLink {
        nonisolated let transport: TransportKind = .webRTC
        nonisolated let states = AsyncStream<LinkState> { $0.finish() }
        let receiver = Receiver()
        var calls: [[String: String]] = []
        let fails: Bool

        init(fails: Bool = false) { self.fails = fails }

        func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
            #expect(service == "upload")
            calls.append(args)
            if fails { throw LinkError(code: "offline", message: "Disconnected") }
            return receiver
        }

        func ping() async throws -> UInt32 { 1 }
        func close() async {}
    }

    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("push-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Patterned bytes, including the final partial chunk, exercise content as well as length.
    func writeOriginal(_ url: URL) throws -> (size: Int, digest: Data) {
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var hash = SHA256()
        for index in 0..<33 {
            let bytes = Data(repeating: UInt8(index), count: 1 << 20)
            try handle.write(contentsOf: bytes)
            hash.update(data: bytes)
        }
        let tail = Data(repeating: 0xAF, count: 17)
        try handle.write(contentsOf: tail)
        hash.update(data: tail)
        return ((33 << 20) + tail.count, Data(hash.finalize()))
    }

    @Test(arguments: ["archive.unusual", "photo.png"])
    func pickedOriginalReachesPromptWithoutItsPreview(_ originalName: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(originalName)
        let expected = try writeOriginal(source)
        let outbox = PushOutbox(directory: root.appendingPathComponent("outbox"))
        let picked = try PushPickedFile(source, outbox: outbox)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(PushPickedFile.previewURL(picked.url) == nil)
        try outbox.stage([picked.name], for: "notification")
        let names = outbox.takeStaged(for: "notification")
        #expect(names == [picked.name])

        let files = try PushReplyAttachments.files(names, outbox: outbox)
        #expect(files.count == 1 && files[0].data == nil)
        #expect(files.first?.fileURL == picked.url)
        let link = Link()
        let blocks = try await PushReplyAttachments.blocks(text: "Read this", names: names, outbox: outbox, link: link)
        #expect(blocks.count == 2)
        #expect(blocks[0]["text"]?.stringValue == "Read this")
        #expect(blocks[1]["type"]?.stringValue == "resource_link")
        #expect(blocks[1]["uri"]?.stringValue == "file:///uploads/original")
        #expect(blocks[1]["name"]?.stringValue == picked.name)
        #expect(await link.calls == [["name": picked.name, "size": String(expected.size)]])
        #expect(await link.receiver.bytes == expected.size)
        #expect(await link.receiver.largestWrite == 192 << 10)
        #expect(await link.receiver.digest() == expected.digest)
        #expect(FileManager.default.fileExists(atPath: picked.url.path))
        outbox.removeAttachments(names)
        #expect(!FileManager.default.fileExists(atPath: picked.url.path))
    }

    @Test func missingFilesNeverBecomeAnAttachmentFreePrompt() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = PushOutbox(directory: root)
        let link = Link()
        await #expect(throws: LinkUpload.Failure.self) {
            try await PushReplyAttachments.blocks(text: "Read this", names: ["gone.bin"], outbox: outbox, link: link)
        }
        #expect(await link.calls.isEmpty)
        await #expect(throws: LinkUpload.Failure.self) {
            try await PushReplyAttachments.blocks(text: "Read this", names: ["gone.bin"], outbox: nil, link: link)
        }
    }

    @Test func failedUploadRetainsOriginalForRetry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("small.txt")
        try Data("keep me".utf8).write(to: source)
        let outbox = PushOutbox(directory: root.appendingPathComponent("outbox"))
        let picked = try PushPickedFile(source, outbox: outbox)
        #expect(PushPickedFile.previewURL(picked.url) == picked.url)
        await #expect(throws: LinkUpload.Failure.self) {
            try await PushReplyAttachments.blocks(text: "", names: [picked.name], outbox: outbox, link: Link(fails: true))
        }
        #expect(try String(contentsOf: picked.url, encoding: .utf8) == "keep me")
    }

    @Test func invalidNamesCannotReadOutsideTheOutbox() throws {
        let outbox = PushOutbox(directory: URL(fileURLWithPath: "/unused"))
        #expect(throws: PushOutbox.Refused.self) { try PushReplyAttachments.files(["../private"], outbox: outbox) }
        #expect(throws: PushOutbox.Refused.self) { try PushReplyAttachments.files([".hidden"], outbox: outbox) }
    }
}
