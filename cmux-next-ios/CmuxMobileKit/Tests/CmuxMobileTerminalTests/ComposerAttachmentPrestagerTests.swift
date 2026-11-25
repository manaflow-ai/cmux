#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileTransport
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

@MainActor
@Suite struct ComposerAttachmentPrestagerTests {
    actor UploadProbe {
        var names: [String] = []
        var waiter: CheckedContinuation<Void, Never>?

        func upload(_ name: String) async throws -> String {
            names.append(name)
            waiter?.resume()
            waiter = nil
            try await Task.sleep(for: .hours(1))
            return "/tmp/\(name)"
        }

        func waitForStart() async {
            if !names.isEmpty { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }

    private func attachment(name: String = "clip.mov") -> ComposerAttachment {
        ComposerAttachment(kind: .video, name: name, data: Data("video".utf8))
    }

    @Test func largeStaticImagesUseA2048PixelTransferCopy() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 4096, height: 2048)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4096, height: 2048))
        }
        let original = try #require(source.jpegData(compressionQuality: 0.9))
        let attachment = ComposerAttachment(kind: .image, name: "photo.heic", data: original)
        let transfer = try attachment.transferPayload()
        guard case .data(let data) = transfer.payload else { Issue.record("image transfer was not data"); return }
        #expect(transfer.name == "photo.jpg")
        let resized = try #require(UIImage(data: data))
        #expect(max(resized.size.width * resized.scale, resized.size.height * resized.scale) <= 2048)
    }

    @Test func undecodableImageKeepsItsOriginalBytes() throws {
        let original = Data("not an image".utf8)
        let attachment = ComposerAttachment(kind: .image, name: "photo.bin", data: original)
        let transfer = try attachment.transferPayload()
        #expect(transfer.name == "photo.bin")
        #expect(transfer.payload == .data(original))
    }

    @Test func pickingStartsOneUploadAndSendClaimsIt() async throws {
        let probe = UploadProbe()
        let prestager = ComposerAttachmentPrestager()
        let file = attachment()
        prestager.sync([file], upload: { _, name in try await probe.upload(name) })
        await probe.waitForStart()

        let claimed = prestager.claim([file])
        #expect(prestager.entries.isEmpty)
        let entry = try #require(claimed[file.id])
        entry.task.cancel()
        await #expect(throws: CancellationError.self) { try await entry.task.value }
    }

    @Test func removingAnAttachmentCancelsItsEarlyUpload() async throws {
        let probe = UploadProbe()
        let prestager = ComposerAttachmentPrestager()
        let file = attachment()
        prestager.sync([file], upload: { _, name in try await probe.upload(name) })
        await probe.waitForStart()
        let task = try #require(prestager.entries[file.id]?.task)
        prestager.sync([], upload: { _, name in try await probe.upload(name) })
        #expect(prestager.entries.isEmpty)
        #expect(task.isCancelled)
    }

    @Test func cancellingSendKeepsTheDraftAndTiles() async throws {
        final class Session: TerminalSession {
            let programName = "zsh"
            let isAlternateScreen = false
            func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {}
            func send(_ bytes: Data) {}
            func resize(columns: Int, rows: Int) {}
            func stop() {}
        }

        let probe = UploadProbe()
        let model = TerminalModel(session: Session(), artifactSource: UnavailableArtifactSource(), title: "attachments")
        model.uploader = { _, name in try await probe.upload(name) }
        let file = attachment()
        model.addAttachment(file)
        await probe.waitForStart()
        model.composerText = "send this after retry"
        model.send()
        #expect(model.isUploading)
        model.cancelAttachmentSend()
        #expect(!model.isUploading)
        #expect(model.composerText == "send this after retry")
        #expect(model.attachments.map(\.id) == [file.id])
    }
}
#endif
