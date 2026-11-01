import Darwin
@testable import CmuxNextDictation
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A long dictation recording for a chat on another computer (an ssh peer's acpmux, a Cloud chat):
/// the page asks `dictation.recording.upload {path}` with the path the host gave it, and the host
/// streams that file from its own disk through the chat's upload stager, answering where it went on
/// the chat's machine. Only a recording this pane's dictation wrote, for this chat, goes, and once.
/// Leo, 2026-10-26: "I ALREADY SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE".
@Suite
@MainActor
struct AgentPaneDictationUploadTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The recordings a failed upload gave back to the pane's dictation, with their chats.
    private final class GivenBack {
        var recordings: [(recording: AgentPaneIssuedRecording, session: String)] = []
    }

    /// `file` as the recording issued it: the file at its path now.
    private func issued(_ file: URL) throws -> AgentPaneIssuedRecording {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        defer { if descriptor >= 0 { close(descriptor) } }
        return AgentPaneIssuedRecording(file: file, identity: try #require(DictationFileIdentity.of(descriptor: descriptor)))
    }

    private static let someFile = DictationFileIdentity(device: 1, inode: 42)

    /// A chat's stager as the App's peer and Cloud stagers answer: a token and the chunk size on
    /// begin, the offset on each chunk, where the file went on finish. It keeps what it was sent.
    private final class Stager {
        var requests: [AgentPaneUploadStageRequest] = []
        var sessions: [String?] = []
        var received = Data()
        var finish: [String: Any] = AgentPaneReply.success(["path": "/home/me/.acpmux/uploads/chat-a/Recording.wav"])
        /// The chunk the stager refuses (its machine dropped), if any.
        var failsAtChunk: Int?
        /// Runs as each chunk arrives (the page's × landing mid-upload).
        var onChunk: (@MainActor () async -> Void)?
        /// Runs while the finish is pending, before it commits (the remote transfer in flight): the
        /// finish is released when this returns.
        var duringFinish: (@MainActor () async -> Void)?
        /// The files a finish committed on the chat's machine. A finish whose task was cancelled
        /// before it commits commits nothing, as the real stagers' transfers stop on cancellation
        /// (Cloud's `cmux link access upload` child is killed by ProcessRunner).
        var committed: [String] = []
        private var chunkCount = 0

        var stage: AgentPaneUploadStager {
            { [self] request, session in
                requests.append(request)
                sessions.append(session)
                switch request {
                case .begin(_, let size, _, _):
                    return AgentPaneReply.success(["token": "t1", "size": size, "chunkSize": 512 * 1024])
                case .chunk(_, let offset, let data):
                    chunkCount += 1
                    await onChunk?()
                    if chunkCount - 1 == failsAtChunk { return AgentPaneReply.failure(code: "upload_failed", message: "Couldn't send the file to huge-blue.") }
                    received.append(data)
                    return AgentPaneReply.success(["offset": offset + data.count])
                case .finish:
                    await duringFinish?()
                    if Task.isCancelled { return AgentPaneReply.failure(code: "upload_failed", message: "The transfer was stopped.") }
                    if finish["ok"] as? Bool == true, let path = (finish["value"] as? [String: Any])?["path"] as? String { committed.append(path) }
                    return finish
                case .cancel:
                    return AgentPaneReply.success()
                }
            }
        }
    }

    /// A recording file of `bytes` bytes in its own temporary folder; the folder goes with the test.
    private func recordingFile(bytes: Int) throws -> (URL, Data) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dictation-upload-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Recording.wav")
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: file)
        return (file, data)
    }

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    private func upload(_ path: String, in model: AgentPaneModel) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": "dictation.recording.upload", "params": ["path": path]]))
    }

    @Test func thePageAsksWithTheHostsPathOnly() {
        #expect(AgentPaneRequest(body: ["method": "dictation.recording.upload", "params": ["path": "/tmp/a/Recording.wav"]])
            == .dictationRecordingUpload(path: "/tmp/a/Recording.wav"))
        #expect(AgentPaneRequest(body: ["method": "dictation.recording.upload", "params": ["path": "Recording.wav"]])
            == .unsupported("dictation.recording.upload"))
        #expect(AgentPaneRequest(body: ["method": "dictation.recording.upload"]) == .unsupported("dictation.recording.upload"))
        #expect(AgentPageOps.methods["dictation.recording.upload"] == "dictation.recording.upload")
        #expect(AgentPaneRequest(body: ["method": "dictation.recording.cancel", "params": ["path": "/tmp/a/Recording.wav"]])
            == .dictationRecordingCancel(path: "/tmp/a/Recording.wav"))
        #expect(AgentPaneRequest(body: ["method": "dictation.recording.cancel", "params": ["path": "Recording.wav"]])
            == .unsupported("dictation.recording.cancel"))
        #expect(AgentPageOps.methods["dictation.recording.cancel"] == "dictation.recording.cancel")
        #expect(!AgentPaneRequest.dictationRecordingUpload(path: "/Users/me/secret.wav").description.contains("secret"))
    }

    /// The pane keeps the long recordings it handed the page, with the chat each was made in; the
    /// page can take one back only for that chat, and only once. A short recording (inline) and a
    /// path the page made up are never taken.
    @Test func onlyARecordingThisPaneWroteForThisChatIsTakenOnce() {
        let dictation = AgentPaneDictation(send: { _ in }, microphone: DictationMicrophone())
        var chat: String? = "chat-a"
        dictation.chatSession = { chat }
        let file = URL(filePath: "/tmp/cmux-dictation/one/Recording.wav")
        dictation.deliver(DictationUpdate(phase: .idle, text: "a long one", audio: DictationAudio(file: file, byteCount: 9_600_044, fileIdentity: Self.someFile)), recordedIn: "chat-a")
        dictation.deliver(DictationUpdate(phase: .idle, text: "short", audio: DictationAudio(byteCount: 4, data: Data("RIFF".utf8))), recordedIn: "chat-a")
        // A file with no identity (the writer could not read it) is never handed out.
        let unknown = URL(filePath: "/tmp/cmux-dictation/two/Recording.wav")
        dictation.deliver(DictationUpdate(phase: .idle, text: "", audio: DictationAudio(file: unknown, byteCount: 9_600_044)), recordedIn: "chat-a")
        chat = "chat-b"
        #expect(dictation.takeRecording("/etc/passwd", session: "chat-a") == nil)
        #expect(dictation.takeRecording(unknown.path, session: "chat-a") == nil)
        #expect(dictation.takeRecording(file.path, session: "chat-b") == nil, "another chat's recording")
        #expect(dictation.takeRecording(file.path, session: "chat-a") == AgentPaneIssuedRecording(file: file, identity: Self.someFile))
        #expect(dictation.takeRecording(file.path, session: "chat-a") == nil, "taken once")
    }

    /// A recording whose upload failed is given back for its chat, so the chip's Retry can send it
    /// again; it is still taken only once per try.
    @Test func aRecordingWhoseUploadFailedCanBeTakenAgain() throws {
        let dictation = AgentPaneDictation(send: { _ in }, microphone: DictationMicrophone())
        dictation.chatSession = { "chat-a" }
        let file = URL(filePath: "/tmp/cmux-dictation/one/Recording.wav")
        dictation.deliver(DictationUpdate(phase: .idle, text: "a long one", audio: DictationAudio(file: file, byteCount: 9_600_044, fileIdentity: Self.someFile)), recordedIn: "chat-a")
        let recording = try #require(dictation.takeRecording(file.path, session: "chat-a"))
        dictation.giveBackRecording(recording, session: "chat-a")
        #expect(dictation.takeRecording(file.path, session: "chat-b") == nil, "given back for its own chat only")
        #expect(dictation.takeRecording(file.path, session: "chat-a") == recording)
        #expect(dictation.takeRecording(file.path, session: "chat-a") == nil, "taken once per try")
    }

    /// The pane forgets old recordings past a few: what it holds stays small however long it lives.
    @Test func thePaneHoldsAFewRecordingsAtMost() {
        let dictation = AgentPaneDictation(send: { _ in }, microphone: DictationMicrophone())
        dictation.chatSession = { "chat-a" }
        let files = (0..<(AgentPaneDictation.issuedRecordingLimit + 1)).map { URL(filePath: "/tmp/cmux-dictation/\($0)/Recording.wav") }
        for file in files {
            dictation.deliver(DictationUpdate(phase: .idle, text: "", audio: DictationAudio(file: file, byteCount: 5_000_000, fileIdentity: Self.someFile)), recordedIn: "chat-a")
        }
        #expect(dictation.takeRecording(files[0].path, session: "chat-a") == nil, "the oldest is forgotten")
        #expect(dictation.takeRecording(files[files.count - 1].path, session: "chat-a")?.file == files[files.count - 1])
    }

    /// The file streams from disk through the chat's own stager, one bounded chunk at a time, with
    /// no gesture of the page's (the recording is the host's own), and the reply is the path on the
    /// chat's machine.
    @Test func aRecordingStreamsThroughTheChatsStager() async throws {
        let (file, data) = try recordingFile(bytes: 1_300_000)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-a")
        let stager = Stager()
        model.onUploadStage = { stager.stage }
        let recording = try issued(file)
        model.onDictationRecording = { path, session in path == file.path && session == "chat-a" ? recording : nil }
        let givenBack = GivenBack()
        model.onDictationRecordingUnsent = { recording, session in givenBack.recordings.append((recording, session)) }
        let reply = await upload(file.path, in: model)
        #expect(reply["ok"] as? Bool == true)
        #expect(givenBack.recordings.isEmpty, "a sent recording is not given back")
        #expect((reply["value"] as? [String: Any])?["path"] as? String == "/home/me/.acpmux/uploads/chat-a/Recording.wav")
        #expect(stager.requests.first == .begin(name: "Recording.wav", size: data.count, batchToken: nil, batch: nil))
        #expect(stager.received == data)
        #expect(stager.sessions.allSatisfy { $0 == "chat-a" })
        var chunks: [Int] = []
        for case .chunk(_, _, let bytes) in stager.requests { chunks.append(bytes.count) }
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0 <= 512 * 1024 })
        #expect(stager.requests.last == .finish(token: "t1"))
        // The local file stays: the launch sweep removes it with the chat's other uploads.
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// A Cloud chat's stager answers `{uploads: [{name, path}]}`; the page gets the one path.
    @Test func aCloudStagersAnswerIsOnePath() async throws {
        let (file, _) = try recordingFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-a")
        let stager = Stager()
        stager.finish = AgentPaneReply.success(["uploads": [["name": "Recording.wav", "path": "/root/work/Recording.wav"]]])
        model.onUploadStage = { stager.stage }
        let recording = try issued(file)
        model.onDictationRecording = { _, _ in recording }
        let reply = await upload(file.path, in: model)
        #expect((reply["value"] as? [String: Any])?["path"] as? String == "/root/work/Recording.wav")
    }

    /// A path the pane did not hand out is refused before anything is read or staged.
    @Test func aPathThePaneDidNotIssueIsRefused() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-a")
        let stager = Stager()
        model.onUploadStage = { stager.stage }
        model.onDictationRecording = { _, _ in nil }
        let reply = await upload("/Users/me/.ssh/id_ed25519", in: model)
        #expect(Self.errorCode(reply) == "dictation.not_a_recording")
        #expect(stager.requests.isEmpty)
        // A chat with no stager (a local chat, or none at all) takes no upload either.
        let local = AgentPaneModel(host: NoHost(), sessionId: "chat-a")
        local.onDictationRecording = { _, _ in AgentPaneIssuedRecording(file: URL(filePath: "/tmp/x.wav"), identity: Self.someFile) }
        #expect(Self.errorCode(await upload("/tmp/x.wav", in: local)) == "unsupported")
    }

    /// A stager that fails mid-way gets a cancel (it drops what it staged), and the page the failure.
    @Test func aFailedChunkCancelsTheStage() async throws {
        let (file, _) = try recordingFile(bytes: 1_300_000)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-a")
        let stager = Stager()
        stager.failsAtChunk = 1
        model.onUploadStage = { stager.stage }
        let recording = try issued(file)
        model.onDictationRecording = { _, _ in recording }
        let givenBack = GivenBack()
        model.onDictationRecordingUnsent = { recording, session in givenBack.recordings.append((recording, session)) }
        let reply = await upload(file.path, in: model)
        #expect(Self.errorCode(reply) == "upload_failed")
        // Given back for its chat, so the page's Retry can send it again.
        #expect(givenBack.recordings.map(\.recording) == [recording])
        #expect(givenBack.recordings.map(\.session) == ["chat-a"])
        #expect(stager.requests.last == .cancel(token: "t1"))
        #expect(!stager.requests.contains(.finish(token: "t1")))
    }

    /// Review of #26953 at 92225ed0: the chip's × only dropped the page's tile, while the host read
    /// and sent the whole file. The × (`dictation.recording.cancel`) stops the upload before its
    /// next chunk and cancels the stage, so nothing is left on the chat's machine.
    @Test func theChipsCancelStopsTheUploadAndItsStage() async throws {
        let (file, _) = try recordingFile(bytes: 1_300_000)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-a")
        let stager = Stager()
        stager.onChunk = { [model] in
            _ = await model.respond(to: AgentPaneRequest(body: ["method": "dictation.recording.cancel", "params": ["path": file.path]]))
        }
        model.onUploadStage = { stager.stage }
        let recording = try issued(file)
        model.onDictationRecording = { _, _ in recording }
        let reply = await upload(file.path, in: model)
        #expect(Self.errorCode(reply) == "cancelled")
        let chunks = stager.requests.filter { if case .chunk = $0 { true } else { false } }
        #expect(chunks.count == 1, "no chunk after the ×")
        #expect(stager.requests.last == .cancel(token: "t1"))
        #expect(!stager.requests.contains(.finish(token: "t1")))
        #expect(model.dictationUploads.running.isEmpty && model.dictationUploads.cancelled.isEmpty)
        // A × for a path not uploading leaves nothing behind for a later upload of it.
        _ = await model.respond(to: AgentPaneRequest(body: ["method": "dictation.recording.cancel", "params": ["path": file.path]]))
        #expect(model.dictationUploads.cancelled.isEmpty)
    }

    /// Review of #26953 at 92225ed0: the file's type was checked by path and each chunk opened it
    /// again, so a link swapped in between went out. A link is refused, and the file is read
    /// through the one descriptor it was opened with.
    @Test func aLinkAtTheRecordingsPathIsNotFollowed() async throws {
        let (file, data) = try recordingFile(bytes: 1_300_000)
        let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = folder.appending(path: "secret.txt")
        try Data("secret".utf8).write(to: secret)
        let link = folder.appending(path: "Link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let refused = Stager()
        let linked = AgentPaneIssuedRecording(file: link, identity: try issued(secret).identity)
        #expect(Self.errorCode(await AgentPaneDictationUpload.send(linked, through: refused.stage, session: "chat-a")) == "upload_failed")
        #expect(refused.requests.isEmpty)
        // Swapped for a link after it was opened: the bytes are still the recording's.
        let stager = Stager()
        stager.onChunk = {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == nil else { return }
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)
        }
        let reply = await AgentPaneDictationUpload.send(try issued(file), through: stager.stage, session: "chat-a")
        #expect(reply["ok"] as? Bool == true)
        #expect(stager.received == data)
    }

    /// Review of #26953 at ae1fbc05: the host checked only the path it issued, so another regular
    /// file (or a hard link to one) put there before the upload went out. Only the file the
    /// recording wrote goes: one put at its path since is refused before anything is staged.
    @Test func aFilePutAtTheRecordingsPathSinceIsRefused() async throws {
        let (file, _) = try recordingFile(bytes: 1_000)
        let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recording = try issued(file)
        let secret = folder.appending(path: "secret.txt")
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.linkItem(at: secret, to: file)
        let stager = Stager()
        #expect(Self.errorCode(await AgentPaneDictationUpload.send(recording, through: stager.stage, session: "chat-a")) == "upload_failed")
        #expect(stager.requests.isEmpty)
    }

    /// Review of #26953 at ae1fbc05: a finish that failed, or answered no usable path, left the
    /// stage behind. It is cancelled.
    @Test(arguments: [false, true])
    func aFinishWithNoPathCancelsTheStage(fails: Bool) async throws {
        let (file, _) = try recordingFile(bytes: 1_000)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let stager = Stager()
        stager.finish = fails
            ? AgentPaneReply.failure(code: "upload_failed", message: "Couldn't send the file to huge-blue.")
            : AgentPaneReply.success(["path": "relative.wav"])
        let reply = await AgentPaneDictationUpload.send(try issued(file), through: stager.stage, session: "chat-a")
        #expect(Self.errorCode(reply) == "upload_failed")
        #expect(stager.requests.last == .cancel(token: "t1"))
    }

    /// Review of #27012: cancellation was checked before the stager's finish but not during it, so
    /// a × while the finish's remote transfer ran (Cloud's `cmux link access upload`, a peer's
    /// file_put) let it commit a file on the chat's machine after the page dropped the chip. The
    /// finish runs in its own task, which the × cancels; the upload answers `cancelled` and does not
    /// give the recording back.
    @Test func aCancelWhileTheFinishIsPendingStopsItBeforeItCommits() async throws {
        let (file, _) = try recordingFile(bytes: 1_300_000)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-a")
        let stager = Stager()
        stager.duringFinish = { [model] in
            _ = await model.respond(to: AgentPaneRequest(body: ["method": "dictation.recording.cancel", "params": ["path": file.path]]))
        }
        model.onUploadStage = { stager.stage }
        let recording = try issued(file)
        model.onDictationRecording = { _, _ in recording }
        let givenBack = GivenBack()
        model.onDictationRecordingUnsent = { recording, session in givenBack.recordings.append((recording, session)) }
        let reply = await upload(file.path, in: model)
        #expect(stager.requests.contains(.finish(token: "t1")))
        #expect(stager.committed.isEmpty, "no file is left on the chat's machine")
        #expect(Self.errorCode(reply) == "cancelled")
        #expect((reply["value"] as? [String: Any])?["path"] == nil)
        #expect(givenBack.recordings.isEmpty, "a removed recording is not given back for Retry")
        #expect(model.dictationUploads.running.isEmpty && model.dictationUploads.cancelled.isEmpty)
        #expect(model.dictationUploads.finishing.isEmpty)
    }

    /// Review of #27012 at 6a9fa4bf: a finish that ignored the cancel and committed answered its
    /// path, as if the × had never come. It answers `cancelled`; the committed copy stays, since no
    /// stager can delete one.
    @Test func aFinishThatCommitsDespiteTheCancelStillAnswersCancelled() async throws {
        let (file, _) = try recordingFile(bytes: 1_000)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let stager = Stager()
        var asked = 0
        let reply = await AgentPaneDictationUpload.send(try issued(file), through: stager.stage, session: "chat-a", cancelled: {
            // False through the chunks and the check before the finish; true once the finish ran.
            defer { asked += 1 }
            return stager.requests.contains(.finish(token: "t1"))
        })
        #expect(asked > 0)
        #expect(stager.requests.contains(.finish(token: "t1")))
        #expect(Self.errorCode(reply) == "cancelled")
        #expect((reply["value"] as? [String: Any])?["path"] == nil)
    }
}
