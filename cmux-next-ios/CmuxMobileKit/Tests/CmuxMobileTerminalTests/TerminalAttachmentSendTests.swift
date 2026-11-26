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
        var submitted: [String] = []
        func sendPasteAndSubmit(_ text: String, notSent: @escaping @MainActor () -> Void,
                                maybeSent: @escaping @MainActor () -> Void) -> Bool {
            submitted.append(text)
            return true
        }
    }

    /// An upload queue the test drives: starts are recorded, waits finish when told.
    @MainActor
    final class FakeSender: TerminalAttachmentSending {
        var started: [String] = []
        var waited: [String] = []
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
            waited.append(uploadID)
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

    static func model(session: QuietSession = QuietSession()) -> TerminalModel {
        TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "attach")
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

    static func waitFor(_ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !condition(), clock.now < deadline { await Task.yield() }
        return condition()
    }

    @Test func stopCancelsActiveTransfersAndRetryReusesOnlyCompletedPaths() async {
        let session = QuietSession()
        let model = Self.model(session: session)
        let sender = FakeSender()
        model.attachmentSender = sender
        for _ in 0..<3 { model.addAttachment(Self.video()) }
        sender.finish("u1", .success("/mac/ready"))
        model.composerText = "see"
        model.send()
        #expect(await Self.waitFor { sender.waited.contains("u2") })
        model.cancelSend()
        #expect(!model.isUploading)
        #expect(sender.cancelled == ["u2", "u3"])
        #expect(model.attachments.map(\.uploadID) == ["u1", nil, nil])
        #expect(model.composerText == "see")
        #expect(session.submitted.isEmpty)

        model.send()
        #expect(sender.started == ["u1", "u2", "u3", "u4", "u5"])
        sender.finish("u4", .success("/mac/retry1"))
        sender.finish("u5", .success("/mac/retry2"))
        #expect(await Self.waitFor { !model.isUploading })
        #expect(session.submitted == ["/mac/ready /mac/retry1 /mac/retry2 see"])
        #expect(model.attachments.isEmpty)
    }

    @Test func removingAnAlreadyResolvedPathInvalidatesTheSendWaitingOnAnotherFile() async {
        let session = QuietSession()
        let model = Self.model(session: session)
        let sender = FakeSender()
        model.attachmentSender = sender
        let first = Self.video()
        model.addAttachment(first)
        model.addAttachment(Self.video())
        sender.finish("u1", .success("/mac/removed"))
        model.composerText = "look"
        model.send()
        #expect(await Self.waitFor { sender.waited == ["u1", "u2"] })
        model.removeAttachment(first.id)
        sender.finish("u2", .success("/mac/kept"))
        #expect(!model.isUploading)
        #expect(model.composerText == "look")
        #expect(model.attachments.count == 1)
        model.send()
        #expect(sender.started == ["u1", "u2"])
        #expect(await Self.waitFor { !model.isUploading })
        #expect(session.submitted == ["/mac/kept look"])
    }

    @Test func removingAPickAddedAfterSendKeepsThatSendActive() async {
        let session = QuietSession()
        let model = Self.model(session: session)
        let sender = FakeSender()
        model.attachmentSender = sender
        model.addAttachment(Self.video())
        model.composerText = "first"
        model.send()
        let later = Self.video()
        model.addAttachment(later)
        model.removeAttachment(later.id)
        #expect(model.isUploading)
        #expect(sender.cancelled == ["u2"])
        sender.finish("u1", .success("/mac/first"))
        #expect(await Self.waitFor { !model.isUploading })
        #expect(session.submitted == ["/mac/first first"])
    }

    /// The legacy uploader may still return a path after its Task was cancelled.
    @Test func removingALegacyPickDiscardsPathsAndDoesNotStartTheNextUpload() async throws {
        let session = QuietSession()
        let model = Self.model(session: session)
        let first = Self.video()
        var waiting: CheckedContinuation<String, Never>?
        var calls = 0
        model.uploader = { _, _ in
            calls += 1
            if calls == 2 { return await withCheckedContinuation { waiting = $0 } }
            return "/mac/item\(calls)"
        }
        model.addAttachment(first)
        model.addAttachment(Self.video())
        model.addAttachment(Self.video())
        model.composerText = "keep"
        model.send()
        try #require(await Self.waitFor { waiting != nil })
        model.removeAttachment(first.id)
        let late = try #require(waiting)
        late.resume(returning: "/mac/late")
        #expect(!model.isUploading)
        model.send()
        #expect(await Self.waitFor { !model.isUploading })
        #expect(calls == 4)
        #expect(session.submitted == ["/mac/item3 /mac/item4 keep"])
    }

    @Test func pickerCopyLivesThroughStopAndPreviewThenReleasesItsDirectory() async throws {
        let files = FileManager.default
        let source = files.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        try Data([1, 2, 3]).write(to: source)
        defer { try? files.removeItem(at: source) }
        let model = Self.model()
        let sender = FakeSender()
        model.attachmentSender = sender
        let tile = ComposerAttachment(kind: .video, name: "Clip.mov", isLoading: true)
        model.addAttachment(tile)
        let copied: URL
        do {
            let movie = try PickedMovieCopy(copying: source)
            copied = movie.url
            model.attachmentLoaded(tile.id, thumbnail: nil, byteCount: 3, fileURL: movie.url, pickedMovie: movie)
        }
        model.send()
        model.cancelSend()
        #expect(files.fileExists(atPath: copied.path))
        var preview: FilePreviewRequest? = FilePreviewRequest(files: model.attachments.map(\.localFile), startingAt: nil)
        model.send()
        sender.finish("u2", .success("/mac/clip"))
        try #require(await Self.waitFor { !model.isUploading })
        #expect(model.attachments.isEmpty)
        #expect(preview?.artifacts.count == 1)
        #expect(files.fileExists(atPath: copied.path))
        preview = nil
        #expect(await Self.waitFor { !files.fileExists(atPath: copied.deletingLastPathComponent().path) })
        #expect(files.fileExists(atPath: source.path))
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
