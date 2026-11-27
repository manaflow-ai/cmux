#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileLinkFFI
import CmuxMobileTransport
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
        var refuseSubmission = false
        var expireOnEnd = false
        var submissions: [UUID: @MainActor () -> Void] = [:]
        func beginAttachmentSubmission(onExpire: @escaping @MainActor () -> Void) -> UUID {
            let id = UUID()
            submissions[id] = onExpire
            return id
        }
        func endAttachmentSubmission(_ id: UUID) -> Bool {
            if expireOnEnd { expireSubmissions() }
            return submissions.removeValue(forKey: id) != nil
        }
        func expireSubmissions() {
            let callbacks = Array(submissions.values)
            submissions.removeAll()
            callbacks.forEach { $0() }
        }
        func sendPasteAndSubmit(_ text: String, notSent: @escaping @MainActor () -> Void,
                                maybeSent: @escaping @MainActor () -> Void) -> Bool {
            if refuseSubmission { notSent(); return true }
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
        var forgotten: [String] = []
        var uploadDestination: AttachmentDestination?
        func forget(_ uploadID: String) {
            forgotten.append(uploadID)
            states.removeValue(forKey: uploadID)
            results.removeValue(forKey: uploadID)
        }
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
                UploadProgress(uploadId: uploadID, stage: $0, ackedBytes: 0, confirmedBytes: 0, sentBytes: 0, totalBytes: 10,
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

    @Test func expiredSubmissionKeepsTransferAndDraftForAnExplicitRetry() async {
        let session = QuietSession()
        let model = Self.model(session: session)
        let sender = FakeSender()
        model.attachmentSender = sender
        model.addAttachment(Self.video())
        model.composerText = "original"
        model.send()
        #expect(await Self.waitFor { sender.waited == ["u1"] })
        model.ingest(.connection(.offline(mac: "Mac")))
        model.composerText = "edited while offline"
        session.expireSubmissions()
        #expect(!model.isUploading)
        #expect(sender.cancelled.isEmpty)
        #expect(model.attachments.first?.uploadID == "u1")
        sender.finish("u1", .success("/mac/video"))
        await Self.settle()
        #expect(session.submitted.isEmpty)
        #expect(model.composerText == "edited while offline")
        #expect(model.composerNotice != nil)
        model.ingest(.connection(.attached))
        model.send()
        #expect(await Self.waitFor { !model.isUploading })
        #expect(session.submitted == ["/mac/video edited while offline"])
        #expect(sender.started == ["u1"])
        #expect(sender.forgotten == ["u1"])
    }

    @Test func finishingRechecksExpiryBeforeSubmittingAfterSuspension() async {
        let session = QuietSession()
        let model = Self.model(session: session)
        let sender = FakeSender()
        model.attachmentSender = sender
        model.addAttachment(Self.video())
        model.composerText = "keep"
        model.send()
        #expect(await Self.waitFor { sender.waited == ["u1"] })
        session.expireOnEnd = true
        sender.finish("u1", .success("/mac/video"))
        #expect(await Self.waitFor { !model.isUploading })
        #expect(session.submitted.isEmpty)
        #expect(model.composerText == "keep")
        #expect(model.attachments.count == 1)
    }

    @Test func sendUsesTappedTextAndPreservesLaterEdits() async {
        let session = QuietSession()
        let model = Self.model(session: session)
        let sender = FakeSender()
        model.attachmentSender = sender
        model.addAttachment(Self.video())
        model.composerText = "tapped"
        model.send()
        model.composerText = "next draft"
        sender.finish("u1", .success("/mac/video"))
        #expect(await Self.waitFor { !model.isUploading })
        #expect(session.submitted == ["/mac/video tapped"])
        #expect(model.composerText == "next draft")
        #expect(sender.forgotten == ["u1"])
    }

    @Test func synchronousRefusalPreservesDraftAndCompletedAttachment() async {
        for edited in [false, true] {
            let session = QuietSession()
            session.refuseSubmission = true
            let model = Self.model(session: session)
            let sender = FakeSender()
            model.attachmentSender = sender
            model.addAttachment(Self.video())
            model.composerText = "tapped"
            model.send()
            if edited { model.composerText = "next draft" }
            sender.finish("u1", .success("/mac/video"))
            #expect(await Self.waitFor { !model.isUploading })
            #expect(session.submitted.isEmpty)
            #expect(model.composerText == (edited ? "next draft" : "tapped"))
            #expect(model.attachments.first?.uploadID == "u1")
            #expect(sender.forgotten.isEmpty)
            // No notice: the draft back in the field is the answer (#54757 removed the not-sent banners).
            #expect(model.composerNotice == nil)
            session.refuseSubmission = false
            model.send()
            #expect(await Self.waitFor { !model.isUploading })
            #expect(sender.started == ["u1"])
            #expect(sender.forgotten == ["u1"])
        }
    }

    @Test func changedDirectoryRestagesEvenACompletedUpload() async {
        let session = QuietSession()
        let model = Self.model(session: session)
        let sender = FakeSender()
        sender.uploadDestination = AttachmentDestination(macID: "mac", cwd: "/old")
        model.attachmentSender = sender
        model.addAttachment(Self.video())
        sender.finish("u1", .success("/old/video"))
        sender.uploadDestination = AttachmentDestination(macID: "mac", cwd: "/new")
        model.composerText = "look"
        model.send()
        #expect(sender.started == ["u1", "u2"])
        #expect(sender.forgotten == ["u1"])
        sender.finish("u2", .success("/new/video"))
        #expect(await Self.waitFor { !model.isUploading })
        #expect(session.submitted == ["/new/video look"])
        #expect(sender.forgotten == ["u1", "u2"])
    }

    @Test func directoryChangeDuringSendKeepsDraftInsteadOfSubmittingOldPaths() async {
        let session = QuietSession()
        let model = Self.model(session: session)
        let sender = FakeSender()
        sender.uploadDestination = AttachmentDestination(macID: "mac", cwd: "/old")
        model.attachmentSender = sender
        model.addAttachment(Self.video())
        model.composerText = "keep"
        model.send()
        sender.uploadDestination = AttachmentDestination(macID: "mac", cwd: "/new")
        sender.finish("u1", .success("/old/video"))
        #expect(await Self.waitFor { !model.isUploading })
        #expect(session.submitted.isEmpty)
        #expect(model.composerText == "keep")
        #expect(model.attachments.count == 1)
    }

    @Test func stalledPhotoLoadCancelsItsProgressAfterTheInactivityDeadline() async {
        let progress = Progress(totalUnitCount: 1)
        do {
            let _: Int = try await TerminalComposer.loadWithInactivityDeadline(
                { _ in progress },
                inactivityDeadline: .milliseconds(20),
                progressPoll: .milliseconds(1)
            )
            Issue.record("a stalled Photos request unexpectedly completed")
        } catch {
            #expect(error.localizedDescription == "Photos took too long to provide this item.")
        }
        #expect(progress.isCancelled)
    }

    /// The load runs 1.2 s in all, past one 1 s idle window, while each step
    /// is 20 ms: a 50x margin, so a loaded simulator that stalls a step for
    /// a few hundred ms still sees the load as advancing (a 30 ms step
    /// against 150 ms threw .deadline on CI, job 140513387231).
    @Test func advancingPhotoLoadOutlivesOneIdleWindowAndCompletesWithoutCancellation() async throws {
        let steps: Int64 = 60
        let progress = Progress(totalUnitCount: steps)
        let value: Int = try await TerminalComposer.loadWithInactivityDeadline({ finish in
            Task {
                for step in 1...steps {
                    try await Task.sleep(for: .milliseconds(20))
                    progress.completedUnitCount = step
                }
                finish(.success(42))
            }
            return progress
        }, inactivityDeadline: .seconds(1), progressPoll: .milliseconds(5))
        #expect(value == 42)
        #expect(!progress.isCancelled)
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
        // A loaded CI simulator ran the off-main payload read (`transferPayload`) past the old 2 s
        // (2026-11-27); sleeping, not spinning on `Task.yield()`, leaves the cores to that work.
        let deadline = clock.now + .seconds(10)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5)) // test: polls until a deadline
        }
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
        #expect(sender.forgotten == ["u2", "u3"])
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

    /// The base prestager starts all legacy picks early; a late cancelled path must never submit.
    @Test func removingALegacyPickDiscardsLatePathsAndRetryKeepsOnlyRemainingTiles() async throws {
        let session = QuietSession()
        let model = Self.model(session: session)
        let first = ComposerAttachment(kind: .video, name: "first.mov", data: Data([1]))
        let second = ComposerAttachment(kind: .video, name: "second.mov", data: Data([2]))
        var waiting: CheckedContinuation<String, Never>?
        model.uploader = { _, name in
            if name == "first.mov" { return await withCheckedContinuation { waiting = $0 } }
            return "/mac/" + name
        }
        model.addAttachment(first)
        model.addAttachment(second)
        model.composerText = "keep"
        model.send()
        try #require(await Self.waitFor { waiting != nil })
        model.removeAttachment(first.id)
        let late = try #require(waiting)
        late.resume(returning: "/mac/late")
        await Self.settle()
        #expect(!model.isUploading)
        #expect(session.submitted.isEmpty)
        model.send()
        #expect(await Self.waitFor { !model.isUploading })
        #expect(session.submitted == ["/mac/second.mov keep"])
    }

    @Test func queuedPicksNeverAlsoStartTheLegacyPrestager() async {
        let model = Self.model()
        let sender = FakeSender()
        var legacyCalls = 0
        model.uploader = { _, _ in legacyCalls += 1; return "/mac/duplicate" }
        model.attachmentSender = sender
        model.addAttachment(Self.video())
        model.syncAttachmentUploads()
        await Self.settle()
        #expect(sender.started == ["u1"])
        #expect(legacyCalls == 0)
        model.removeAttachment(model.attachments[0].id)
    }

    @Test func changingMacDiscardsEvenCompletedQueuedPaths() async {
        let model = Self.model()
        let sender = FakeSender()
        model.hostMacID = "first-mac"
        model.attachmentSender = sender
        model.addAttachment(Self.video())
        sender.finish("u1", .success("/first-mac/file"))
        model.hostMacID = "second-mac"
        #expect(model.attachments[0].uploadID == nil)
        #expect(model.attachments[0].uploadSender == nil)
        #expect(model.attachmentSender == nil)
        #expect(sender.cancelled == ["u1"])
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
            model.attachmentLoaded(tile.id, .movie(movie, thumbnail: nil, byteCount: 3))
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

    @Test func removingAMovieDropsItsCopyEvenIfPhotosFinishesAfterRemoval() async throws {
        let files = FileManager.default
        let source = files.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        try Data([1, 2, 3]).write(to: source)
        defer { try? files.removeItem(at: source) }
        for removeWhileLoading in [false, true] {
            let model = Self.model()
            let sender = FakeSender()
            model.attachmentSender = sender
            let tile = ComposerAttachment(kind: .video, name: "Clip.mov", isLoading: true)
            var copied: URL?
            var waiting: CheckedContinuation<Void, Never>?
            model.loadPickedAttachment(tile) {
                let movie = try PickedMovieCopy(copying: source)
                copied = movie.url
                await withCheckedContinuation { waiting = $0 }
                return .movie(movie, thumbnail: nil, byteCount: 3)
            }
            try #require(await Self.waitFor { waiting != nil })
            let directory = try #require(copied).deletingLastPathComponent()
            if removeWhileLoading { model.removeAttachment(tile.id) }
            waiting?.resume()
            if !removeWhileLoading {
                try #require(await Self.waitFor { sender.started.count == 1 })
                #expect(files.fileExists(atPath: directory.path))
                model.removeAttachment(tile.id)
            }
            #expect(await Self.waitFor { !files.fileExists(atPath: directory.path) })
            #expect(sender.started.count == (removeWhileLoading ? 0 : 1))
            #expect(model.attachments.isEmpty)
            #expect(model.attachmentError == nil)
            #expect(files.fileExists(atPath: source.path))
        }
    }

    @Test func reconnectMovesLoadingPicksAndRemovalIgnoresLateCompletion() async throws {
        let before = Self.model()
        let after = Self.model()
        let sender = FakeSender()
        after.attachmentSender = sender
        let keep = ComposerAttachment(kind: .image, name: "one", isLoading: true)
        let remove = ComposerAttachment(kind: .image, name: "two", isLoading: true)
        var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
        var cancelled: [UUID] = []
        for tile in [keep, remove] {
            before.loadPickedAttachment(tile) {
                await withCheckedContinuation { waiting[tile.id] = $0 }
                if Task.isCancelled { cancelled.append(tile.id) }
                return .image(Data([1]), thumbnail: nil)
            }
        }
        try #require(await Self.waitFor { waiting.count == 2 })
        after.adoptComposer(from: before)
        after.removeAttachment(remove.id)
        for continuation in waiting.values { continuation.resume() }
        #expect(await Self.waitFor { cancelled == [remove.id] && sender.started.count == 1 })
        #expect(after.attachments.map(\.id) == [keep.id])
        #expect(after.attachments.first?.isLoading == false)
        #expect(after.attachments.first?.data == Data([1]))
        #expect(after.attachmentError == nil)
        #expect(before.attachments.isEmpty)
    }

    @Test func stopAfterReconnectCancelsTheSenderThatOwnsTheExport() {
        let before = Self.model()
        let after = Self.model()
        let original = FakeSender()
        let replacement = FakeSender()
        before.attachmentSender = original
        after.attachmentSender = replacement
        before.addAttachment(Self.video())
        after.adoptComposer(from: before)
        after.send()
        after.cancelSend()
        #expect(original.cancelled == ["u1"])
        #expect(replacement.cancelled.isEmpty)
        after.send()
        #expect(replacement.started == ["u1"])
        after.cancelSend()
    }

    @Test func aFailedUploadShowsWhyAndSendStartsItAgain() async {
        let model = Self.model()
        let sender = FakeSender()
        model.attachmentSender = sender
        model.addAttachment(Self.video())
        model.send()
        sender.finish("u1", .failure(LinkUploadTestFailure()))
        #expect(await Self.waitFor { !model.isUploading })
        #expect(model.attachmentError?.contains("clip.mov") == true)
        model.send()
        #expect(sender.started == ["u1", "u2"])
        #expect(model.attachments.first?.uploadID == "u2")
        #expect(model.isUploading)
        model.cancelSend()
    }

    struct LinkUploadTestFailure: Error {}
}
#endif
