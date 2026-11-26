import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Files go to the Mac the moment they are picked (Leo: "attachments and shit potentially need to be
/// optimistically transferred from phone to mac"): `AttachmentPrestager` and the prompt that
/// links the early copy instead of uploading again.
@MainActor
@Suite struct AttachmentPrestagerTests {
    /// Counts uploads and answers a path per name; `hold()` holds them until opened.
    actor FakeMac {
        var started: [String] = []
        var gates: [CheckedContinuation<Void, Never>] = []
        var startWaiter: CheckedContinuation<Void, Never>?
        var open = true
        func upload(_ name: String) async throws -> String {
            started.append(name)
            startWaiter?.resume()
            startWaiter = nil
            if !open { await withCheckedContinuation { gates.append($0) } }
            try Task.checkCancellation()
            return "/w/.cmux/attachments/\(name)"
        }
        func hold() { open = false }
        func release() { open = true; gates.forEach { $0.resume() }; gates = [] }
        func waitForUploadStart() async {
            if !started.isEmpty { return }
            await withCheckedContinuation { startWaiter = $0 }
        }
    }

    func file(_ id: String, _ name: String) -> AgentAttachment {
        AgentAttachment(id: id, kind: .file, name: name, data: Data("hello".utf8))
    }

    @Test func onlyFilesThatUploadAtSendGoEarly() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(!AttachmentPrestager.uploadsAtSend(AgentAttachment(kind: .image, name: "p", data: png)))
        #expect(!AttachmentPrestager.uploadsAtSend(AgentAttachment(kind: .file, name: "a.pdf", data: Data("x".utf8))))
        #expect(AttachmentPrestager.uploadsAtSend(AgentAttachment(kind: .file, name: "big.pdf", fileURL: URL(fileURLWithPath: "/tmp/b.pdf"),
                                                                  byteCount: AgentAttachment.maxDocumentBytes + 1)))
        #expect(AttachmentPrestager.uploadsAtSend(file("z", "a.zip")))
        #expect(!AttachmentPrestager.uploadsAtSend(AgentAttachment(kind: .file, name: "clip.mov", macPath: "/w/clip.mov")))
    }

    @Test func pickStartsUploadAndRemovalCancelsIt() async throws {
        let mac = FakeMac()
        await mac.hold()
        let prestager = AttachmentPrestager()
        let upload: AttachmentPrestager.Upload = { _, name in try await mac.upload(name) }
        prestager.sync([file("a", "a.zip"), file("b", "b.log")], upload: upload)
        #expect(Set(prestager.entries.keys) == ["a", "b"])
        let a = try #require(prestager.entries["a"]).task
        // A second sync with the same files starts nothing new.
        prestager.sync([file("a", "a.zip"), file("b", "b.log")], upload: upload)
        prestager.sync([file("b", "b.log")], upload: upload)
        #expect(Set(prestager.entries.keys) == ["b"])
        #expect(a.isCancelled)
        await mac.release()
        let b = try #require(prestager.entries["b"]).task
        #expect(try await b.value == "/w/.cmux/attachments/b.log")
    }

    @Test func sendClaimsUploadsSoEmptyingTheComposerKeepsThem() async throws {
        let prestager = AttachmentPrestager()
        let mac = FakeMac()
        prestager.sync([file("a", "a.zip")], upload: { _, name in try await mac.upload(name) })
        let claimed = prestager.claim([file("a", "a.zip")])
        prestager.sync([], upload: nil)
        let entry = try #require(claimed["a"])
        #expect(!entry.task.isCancelled)
        #expect(try await entry.task.value == "/w/.cmux/attachments/a.zip")
    }

    @Test func noLinkStartsNothing() {
        let prestager = AttachmentPrestager()
        prestager.sync([file("a", "a.zip")], upload: nil)
        #expect(prestager.entries.isEmpty)
    }

    @Test func aChatThatGoesAwayStopsItsUploads() async throws {
        let mac = FakeMac()
        await mac.hold()
        var prestager: AttachmentPrestager? = AttachmentPrestager()
        prestager?.sync([file("a", "a.zip")], upload: { _, name in try await mac.upload(name) })
        let task = try #require(prestager?.entries["a"]).task
        prestager = nil
        #expect(task.isCancelled)
        await mac.release()
    }

    @Test func losingTheLinkCancelsComposerUploads() async throws {
        let prestager = AttachmentPrestager()
        let mac = FakeMac()
        await mac.hold()
        prestager.sync([file("a", "a.zip")], upload: { _, name in try await mac.upload(name) })
        let task = try #require(prestager.entries["a"]).task
        prestager.sync([file("a", "a.zip")], upload: nil)
        #expect(prestager.entries.isEmpty)
        #expect(task.isCancelled)
        await mac.release()
    }

    @Test func sendInAnotherDirectoryDiscardsTheEarlierPath() async throws {
        let mac = FakeMac()
        let prestager = AttachmentPrestager()
        let attachment = file("a", "a.zip")
        await mac.hold()
        prestager.sync([attachment], directory: "/first", upload: { _, name in try await mac.upload(name) })
        await mac.waitForUploadStart()
        let original = try #require(prestager.entries[attachment.id])
        #expect(prestager.claim([attachment], directory: "/second").isEmpty)
        #expect(original.task.isCancelled)
        await mac.release()
    }

    @Test func sameIDImageOptimizationCancelsTheOriginalUpload() async throws {
        let prestager = AttachmentPrestager()
        let mac = FakeMac()
        await mac.hold()
        let upload: AttachmentPrestager.Upload = { _, name in try await mac.upload(name) }
        let original = AgentAttachment(id: "image", kind: .image, name: "photo.heic", data: Data("heic".utf8))
        prestager.sync([original], upload: upload)
        await mac.waitForUploadStart()
        let task = try #require(prestager.entries[original.id]?.task)

        let optimizedData = Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0, 0, 0])
        let optimized = AgentAttachment(id: original.id, kind: .image, name: "photo.png", data: optimizedData)
        prestager.sync([optimized], upload: upload)

        #expect(prestager.entries.isEmpty)
        #expect(task.isCancelled)
        #expect(await mac.started == ["photo.heic"])
        await mac.release()
    }

    /// The prompt links the early copy: no second upload, and no link needed at Send.
    @Test func promptLinksTheEarlyCopy() async throws {
        let prestager = AttachmentPrestager()
        let mac = FakeMac()
        let attachment = file("a", "a.zip")
        prestager.sync([attachment], upload: { _, name in try await mac.upload(name) })
        let blocks = try await AcpmuxSessionSource.promptBlocks(text: "see", attachments: [attachment], link: nil, cwd: "/w",
                                                                macName: "Mac", prestaged: prestager.claim([attachment]))
        #expect(await mac.started == ["a.zip"])
        let encoded = String(decoding: try JSONEncoder().encode(blocks), as: UTF8.self)
        #expect(encoded.contains("a.zip"))
        #expect(encoded.contains("file:"))
    }

    /// An early upload that failed is not the answer: Send tries again (here offline, so it says so).
    @Test func failedEarlyUploadFallsBackToSend() async {
        let prestager = AttachmentPrestager()
        let attachment = file("a", "a.zip")
        prestager.sync([attachment], upload: { _, _ in throw LinkUpload.Failure(code: "closed", message: "gone") })
        await #expect(throws: LinkError.self) {
            _ = try await AcpmuxSessionSource.promptBlocks(text: "see", attachments: [attachment], link: nil, cwd: "/w",
                                                           macName: "Mac", prestaged: prestager.claim([attachment]))
        }
    }
}
