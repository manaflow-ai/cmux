#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileLinkFFI
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-24 (iPhone on LTE, a video to a terminal agent): "it just
/// blocked me endlessly on a send ... i also couldnt cancel out of the send.
/// i need to be able to do that otherwise i cant edit or anything to retry or
/// delete and remove." Send was disabled while uploading and nothing ever
/// cancelled the upload task (design/attachment-upload.md, stage 5).
@MainActor
@Suite struct TerminalAttachmentSendTests {
    final class QuietSession: TerminalSession {
        let programName = "zsh"
        let isAlternateScreen = false
        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {}
        func send(_ bytes: Data) {}
        func resize(columns: Int, rows: Int) {}
        func stop() {}
    }

    /// An upload queue the test drives: starts are recorded, waits finish when told.
    @MainActor
    final class FakeSender: TerminalAttachmentSending {
        var started: [String] = []
        var cancelled: [String] = []
        var states: [String: UploadStage] = [:]
        /// Each finished upload's result: a `wait` that starts after it ends gets it at once,
        /// as the engine's does (its result is a watch channel, attachment_upload.rs).
        private var results: [String: Result<String, any Error>] = [:]
        private var waiters: [String: [CheckedContinuation<String, any Error>]] = [:]

        func start(_ attachment: ComposerAttachment) -> String? {
            let id = "u\(started.count + 1)"
            started.append(id)
            states[id] = .uploading
            return id
        }

        func cancel(_ uploadID: String) {
            cancelled.append(uploadID)
            states[uploadID] = .cancelled
            finish(uploadID, .failure(CancellationError()))
        }

        func wait(_ uploadID: String) async throws -> String {
            if let result = results[uploadID] { return try result.get() }
            return try await withCheckedThrowingContinuation { waiters[uploadID, default: []].append($0) }
        }

        func progress(_ uploadID: String) -> UploadProgress? {
            states[uploadID].map {
                UploadProgress(uploadId: uploadID, stage: $0, ackedBytes: 0, sentBytes: 0, totalBytes: 10,
                               attempt: 1, macPath: nil, errorCode: nil, errorMessage: nil)
            }
        }

        func finish(_ uploadID: String, _ result: Result<String, any Error>) {
            if case .success = result { states[uploadID] = .done }
            if case .failure = result, states[uploadID] != .cancelled { states[uploadID] = .failed }
            results[uploadID] = result
            for waiter in waiters.removeValue(forKey: uploadID) ?? [] { waiter.resume(with: result) }
        }
    }

    static func model() -> TerminalModel {
        TerminalModel(session: QuietSession(), artifactSource: MockArtifactSource(), title: "attach")
    }

    static func video() -> ComposerAttachment {
        ComposerAttachment(kind: .video, name: "clip.mov", data: Data(repeating: 1, count: 64))
    }

    static func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// The old path (`uploader`) with an upload that never ends: Stop frees
    /// the composer in the same call, keeping the text and the attachment.
    @Test func aHungUploadCanBeStoppedAndTheComposerIsFreeAtOnce() async {
        let model = Self.model()
        model.uploader = { _, _ in
            try await Task.sleep(for: .seconds(3600)) // test: an upload that never finishes
            return "/never"
        }
        model.composerText = "look at this"
        model.addAttachment(Self.video())
        model.send()
        #expect(model.isUploading)
        model.cancelSend()
        #expect(!model.isUploading)
        #expect(model.composerText == "look at this")
        #expect(model.attachments.count == 1)
        #expect(model.attachmentError == nil)
        await Self.settle()
        // The cancelled task never comes back to say it failed.
        #expect(model.attachmentError == nil)
        #expect(!model.isUploading)
    }

    @Test func anAttachmentStartsSendingWhenPickedAndRemovingItCancels() {
        let model = Self.model()
        let sender = FakeSender()
        model.attachmentSender = sender
        model.addAttachment(Self.video())
        #expect(sender.started == ["u1"])
        #expect(model.attachments.first?.uploadID == "u1")
        model.removeAttachment(model.attachments[0].id)
        #expect(sender.cancelled == ["u1"])
        #expect(model.attachments.isEmpty)
    }

    @Test func sendWaitsForTheQueueAndStopLeavesTheUploadRunning() async {
        let model = Self.model()
        let sender = FakeSender()
        model.attachmentSender = sender
        model.addAttachment(Self.video())
        model.composerText = "see"
        model.send()
        #expect(model.isUploading)
        model.cancelSend()
        #expect(!model.isUploading)
        // Stop calls the send off, not the upload: a second Send finds it further along.
        #expect(sender.cancelled.isEmpty)
        model.send()
        #expect(sender.started == ["u1"])
        sender.finish("u1", .success("/mac/u1"))
        await Self.settle()
        #expect(!model.isUploading)
        #expect(model.attachments.isEmpty)
        #expect(model.composerText.isEmpty)
    }

    @Test func aFailedUploadShowsWhyAndSendStartsItAgain() async {
        let model = Self.model()
        let sender = FakeSender()
        model.attachmentSender = sender
        model.addAttachment(Self.video())
        model.send()
        sender.finish("u1", .failure(LinkUploadTestFailure()))
        await Self.settle()
        #expect(!model.isUploading)
        #expect(model.attachmentError?.contains("clip.mov") == true)
        model.send()
        #expect(sender.started == ["u1", "u2"])
        #expect(model.attachments.first?.uploadID == "u2")
        #expect(model.isUploading)
    }

    struct LinkUploadTestFailure: Error {}
}
#endif
