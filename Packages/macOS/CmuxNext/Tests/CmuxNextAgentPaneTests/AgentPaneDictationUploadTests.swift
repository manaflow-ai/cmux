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
        var recordings: [(file: URL, session: String)] = []
    }

    /// A chat's stager as the App's peer and Cloud stagers answer: a token and the chunk size on
    /// begin, the offset on each chunk, where the file went on finish. It keeps what it was sent.
    private final class Stager {
        var requests: [AgentPaneUploadStageRequest] = []
        var sessions: [String?] = []
        var received = Data()
        var finish: [String: Any] = AgentPaneReply.success(["path": "/home/me/.acpmux/uploads/chat-a/Recording.wav"])
        /// The chunk the stager refuses (its machine dropped), if any.
        var failsAtChunk: Int?
        /// Runs as the stager takes the begin, before any chunk is read.
        var onBegin: (() -> Void)?
        /// A size limit the stager enforces at begin, as the App's stagers did: Cloud's
        /// (`CloudUploads`, `upload_refused` past 32 MiB) and a peer's (`AgentPeerUploads`,
        /// `too_large` past 1 GiB). Nil once those caps are gone.
        var refusesOver: (bytes: Int, code: String)?
        private var chunkCount = 0

        var stage: AgentPaneUploadStager {
            { [self] request, session in
                requests.append(request)
                sessions.append(session)
                switch request {
                case .begin(_, let size, _, _):
                    onBegin?()
                    if let limit = refusesOver, size > limit.bytes {
                        return AgentPaneReply.failure(code: limit.code, message: "This Mac won't send that file to the Cloud machine.")
                    }
                    return AgentPaneReply.success(["token": "t1", "size": size, "chunkSize": 512 * 1024])
                case .chunk(_, let offset, let data):
                    chunkCount += 1
                    if chunkCount - 1 == failsAtChunk { return AgentPaneReply.failure(code: "upload_failed", message: "Couldn't send the file to huge-blue.") }
                    received.append(data)
                    return AgentPaneReply.success(["offset": offset + data.count])
                case .finish:
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
        dictation.deliver(DictationUpdate(phase: .idle, text: "a long one", audio: DictationAudio(file: file, byteCount: 9_600_044)), recordedIn: "chat-a")
        dictation.deliver(DictationUpdate(phase: .idle, text: "short", audio: DictationAudio(byteCount: 4, data: Data("RIFF".utf8))), recordedIn: "chat-a")
        chat = "chat-b"
        #expect(dictation.takeRecording("/etc/passwd", session: "chat-a") == nil)
        #expect(dictation.takeRecording(file.path, session: "chat-b") == nil, "another chat's recording")
        #expect(dictation.takeRecording(file.path, session: "chat-a") == file)
        #expect(dictation.takeRecording(file.path, session: "chat-a") == nil, "taken once")
    }

    /// A recording whose upload failed is given back for its chat, so the chip's Retry can send it
    /// again; it is still taken only once per try.
    @Test func aRecordingWhoseUploadFailedCanBeTakenAgain() {
        let dictation = AgentPaneDictation(send: { _ in }, microphone: DictationMicrophone())
        dictation.chatSession = { "chat-a" }
        let file = URL(filePath: "/tmp/cmux-dictation/one/Recording.wav")
        dictation.deliver(DictationUpdate(phase: .idle, text: "a long one", audio: DictationAudio(file: file, byteCount: 9_600_044)), recordedIn: "chat-a")
        #expect(dictation.takeRecording(file.path, session: "chat-a") == file)
        dictation.giveBackRecording(file, session: "chat-a")
        #expect(dictation.takeRecording(file.path, session: "chat-b") == nil, "given back for its own chat only")
        #expect(dictation.takeRecording(file.path, session: "chat-a") == file)
        #expect(dictation.takeRecording(file.path, session: "chat-a") == nil, "taken once per try")
    }

    /// The pane forgets old recordings past a few: what it holds stays small however long it lives.
    @Test func thePaneHoldsAFewRecordingsAtMost() {
        let dictation = AgentPaneDictation(send: { _ in }, microphone: DictationMicrophone())
        dictation.chatSession = { "chat-a" }
        let files = (0..<(AgentPaneDictation.issuedRecordingLimit + 1)).map { URL(filePath: "/tmp/cmux-dictation/\($0)/Recording.wav") }
        for file in files {
            dictation.deliver(DictationUpdate(phase: .idle, text: "", audio: DictationAudio(file: file, byteCount: 5_000_000)), recordedIn: "chat-a")
        }
        #expect(dictation.takeRecording(files[0].path, session: "chat-a") == nil, "the oldest is forgotten")
        #expect(dictation.takeRecording(files[files.count - 1].path, session: "chat-a") == files[files.count - 1])
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
        model.onDictationRecording = { path, session in path == file.path && session == "chat-a" ? file : nil }
        let givenBack = GivenBack()
        model.onDictationRecordingUnsent = { file, session in givenBack.recordings.append((file, session)) }
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
        model.onDictationRecording = { _, _ in file }
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
        local.onDictationRecording = { _, _ in URL(filePath: "/tmp/x.wav") }
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
        model.onDictationRecording = { _, _ in file }
        let givenBack = GivenBack()
        model.onDictationRecordingUnsent = { file, session in givenBack.recordings.append((file, session)) }
        let reply = await upload(file.path, in: model)
        #expect(Self.errorCode(reply) == "upload_failed")
        // Given back for its chat, so the page's Retry can send it again.
        #expect(givenBack.recordings.map(\.file) == [file])
        #expect(givenBack.recordings.map(\.session) == ["chat-a"])
        #expect(stager.requests.last == .cancel(token: "t1"))
        #expect(!stager.requests.contains(.finish(token: "t1")))
    }

    /// A stager that refuses the recording at begin (its size limit, Cloud's `upload_refused` or a
    /// peer's `too_large`): the page gets that failure, not a path, and nothing is staged. The pane's
    /// dictation gets the recording back for its chat, so the chip's Retry can send it once the
    /// limit is gone, through the same wiring as AgentPaneView's.
    @Test(arguments: ["upload_refused", "too_large"])
    func aStagerThatRefusesTheSizeFailsAndGivesTheRecordingBackForRetry(code: String) async throws {
        let (file, data) = try recordingFile(bytes: 4_096)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let dictation = AgentPaneDictation(send: { _ in }, microphone: DictationMicrophone())
        dictation.chatSession = { "chat-a" }
        dictation.deliver(DictationUpdate(phase: .idle, text: "a long one", audio: DictationAudio(file: file, byteCount: data.count)), recordedIn: "chat-a")
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-a")
        let stager = Stager()
        stager.refusesOver = (bytes: data.count - 1, code: code)
        model.onUploadStage = { stager.stage }
        model.onDictationRecording = { path, session in dictation.takeRecording(path, session: session) }
        model.onDictationRecordingUnsent = { file, session in dictation.giveBackRecording(file, session: session) }

        let refused = await upload(file.path, in: model)
        #expect(refused["ok"] as? Bool != true)
        #expect(Self.errorCode(refused) == code)
        #expect((refused["value"] as? [String: Any])?["path"] == nil)
        #expect(stager.requests == [.begin(name: "Recording.wav", size: data.count, batchToken: nil, batch: nil)])
        #expect(stager.received.isEmpty)

        // Retry, once the stager takes any size: the recording goes, whole.
        stager.refusesOver = nil
        let retried = await upload(file.path, in: model)
        #expect(retried["ok"] as? Bool == true)
        #expect((retried["value"] as? [String: Any])?["path"] as? String == "/home/me/.acpmux/uploads/chat-a/Recording.wav")
        #expect(stager.received == data)
        #expect(dictation.takeRecording(file.path, session: "chat-a") == nil, "a sent recording is not given back")
    }

    /// Review of #26966: the recording's checks read its path, and each chunk opened the path again,
    /// so an issued recording replaced with a symlink after the check streamed whatever the link
    /// named (any file this user can read) to the chat's machine. The file is opened once, without
    /// following a link, checked as a regular file through that descriptor, and every chunk is read
    /// from it.
    @Test func aRecordingSwappedForASymlinkMidUploadSendsOnlyItsOwnBytes() async throws {
        let (file, data) = try recordingFile(bytes: 1_300_000)
        let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = folder.appending(path: "secret.bin")
        let secretData = Data(repeating: 0x53, count: data.count)
        try secretData.write(to: secret)
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-a")
        let stager = Stager()
        stager.onBegin = {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)
        }
        model.onUploadStage = { stager.stage }
        model.onDictationRecording = { _, _ in file }
        let reply = await upload(file.path, in: model)
        #expect(stager.received != secretData, "the link's file never went")
        #expect(!stager.received.contains(0x53) || stager.received == data)
        if reply["ok"] as? Bool == true { #expect(stager.received == data, "what went is the recording as it was opened") }
    }

    /// An issued recording that is a symlink when the upload starts is refused, and nothing is staged.
    @Test func aRecordingThatIsASymlinkIsRefused() async throws {
        let (file, _) = try recordingFile(bytes: 4_096)
        let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = folder.appending(path: "secret.bin")
        try Data(repeating: 0x53, count: 4_096).write(to: secret)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-a")
        let stager = Stager()
        model.onUploadStage = { stager.stage }
        model.onDictationRecording = { _, _ in file }
        let reply = await upload(file.path, in: model)
        #expect(Self.errorCode(reply) == "upload_failed")
        #expect(stager.requests.isEmpty, "nothing was staged")
    }
}
