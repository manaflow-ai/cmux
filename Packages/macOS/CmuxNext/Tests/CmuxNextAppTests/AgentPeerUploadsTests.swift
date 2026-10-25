import AppKit
import CmuxNextAgentActivity
import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// Files dropped into a chat whose agent runs on an ssh peer (acpmux peering) go to that peer
/// (`_acpmux/file_put`), not to this Mac's Chat Uploads, whose paths that agent cannot open.
@MainActor @Suite struct AgentPeerUploadsTests {
    @Test func aPeerChatGetsThePeerUploaderAndItsDropsAreNeverThisMacsPaths() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let tab = "tab-\(UUID().uuidString)", session = "peer-\(UUID().uuidString)"
        // A chat of this Mac's acpmux, which mirrors the peer's session.
        services.agentTabs.gitLink = { _ in services.agentGit.local }
        services.agentTabs.sessions[tab] = session
        AgentLaneStore.shared.lanes[session] = AgentActivityLane(id: session, name: "huge-blue/fix", title: "fix", peer: "huge-blue",
                                                                 parent: nil, state: .idle, since: nil, error: nil)
        defer { AgentLaneStore.shared.lanes[session] = nil }

        #expect(AgentPeerUploads.target(tab: tab, services: services)?.machine == "huge-blue")
        #expect(AgentPeerUploads.target(tab: tab, services: services)?.session == session)
        #expect(services.agentTabs.uploader?(tab) != nil)
        #expect(services.agentTabs.localPaths?(tab) == false)

        // The same tab once its chat is this Mac's: saved here, Finder drops linked where they are.
        AgentLaneStore.shared.lanes[session] = AgentActivityLane(id: session, name: "fix", title: "fix", peer: nil,
                                                                 parent: nil, state: .idle, since: nil, error: nil)
        #expect(AgentPeerUploads.target(tab: tab, services: services) == nil)
        #expect(services.agentTabs.uploader?(tab) != nil)
        #expect(services.agentTabs.localPaths?(tab) == true)
    }

    @Test func eachFileGoesInTurnAndTheReplyNamesItsPathOnThePeer() async throws {
        let files = [AgentPaneUpload(name: "state.sqlite", data: Data([0, 1])), AgentPaneUpload(name: "state.sqlite", data: Data([2]))]
        var sent: [(String, Data)] = []
        let reply = await AgentPeerUploads.upload(files, machine: "huge-blue") { name, data in
            sent.append((name, data))
            return "/home/me/.acpmux/uploads/s/\(sent.count)/\(name)"
        }
        #expect(sent.map(\.0) == ["state.sqlite", "state.sqlite"])
        #expect(sent.map(\.1) == [Data([0, 1]), Data([2])])
        #expect(reply["ok"] as? Bool == true)
        let uploads = try #require((reply["value"] as? [String: Any])?["uploads"] as? [[String: Any]])
        #expect(uploads.map { $0["name"] as? String } == ["state.sqlite", "state.sqlite"])
        #expect(uploads.map { $0["path"] as? String } == ["/home/me/.acpmux/uploads/s/1/state.sqlite", "/home/me/.acpmux/uploads/s/2/state.sqlite"])
    }

    @Test func anOlderPeerAnswersThatTheChatTakesNoUploads() async {
        for refusal: any Error in [AcpmuxRPCError(code: -32601, name: "filePut.unsupported", message: "Method not found"),
                                   AgentPaneFilePutFailure.unsupported] {
            let reply = await AgentPeerUploads.upload([AgentPaneUpload(name: "a.txt", data: Data("x".utf8))], machine: "huge-blue") { _, _ in
                throw refusal
            }
            #expect(Self.code(reply) == "unsupported", "\(reply)")
        }
        let failed = await AgentPeerUploads.upload([AgentPaneUpload(name: "a.txt", data: Data("x".utf8))], machine: "huge-blue") { _, _ in
            throw AgentPaneFilePutFailure.failed
        }
        #expect(Self.code(failed) == "upload_failed")
    }

    /// A file of any size streams to the peer chunk by chunk as the page sends it (Leo, 2026-10-24:
    /// "we shouldn't have this limit"): nothing of it is kept on this Mac, and each chunk's base64
    /// text goes on as it came.
    @Test func aFilePastTheOldCapStreamsToThePeerChunkByChunk() async throws {
        let peer = FakePeer()
        let target = AgentPeerUploads.Target(session: "s", machine: "huge-blue", host: peer)
        let stages = AgentUploadStages<AgentPeerUploads.Upload>(owner: "test") { _ in }
        let size = 3 * 1024 * 1024 * 1024
        let begun = await AgentPeerUploads.stage(.begin(name: "movie.mov", size: size, batchToken: nil, batch: nil), target: target, stages: stages)
        let value = try #require(begun["value"] as? [String: Any], "\(begun)")
        let token = try #require(value["token"] as? String)
        #expect(value["size"] as? Int == size && value["chunkSize"] as? Int == 512 * 1024)
        let chunk = Data(repeating: 9, count: 512 * 1024).base64EncodedString()
        for offset in stride(from: 0, to: 3 * 512 * 1024, by: 512 * 1024) {
            let wrote = await AgentPeerUploads.stage(.chunk(token: token, offset: offset, base64: chunk), target: target, stages: stages)
            #expect((wrote["value"] as? [String: Any])?["offset"] as? Int == offset + 512 * 1024, "\(wrote)")
        }
        let cancelled = await AgentPeerUploads.stage(.cancel(token: token), target: target, stages: stages)
        #expect(cancelled["ok"] as? Bool == true)
        #expect(stages.count == 0)
        let steps = await peer.steps
        #expect(steps.first == .begin(name: "movie.mov", size: size))
        #expect(steps.dropFirst().prefix(3).allSatisfy { if case .chunk(_, _, let text) = $0 { text == chunk } else { false } })
        #expect(steps.last == .cancel(upload: FakePeer.upload), "the cancel deletes the partial file on the peer")
        // A chunk after the cancel goes nowhere.
        let late = await AgentPeerUploads.stage(.chunk(token: token, offset: 3 * 512 * 1024, base64: chunk), target: target, stages: stages)
        #expect(Self.code(late) == "upload_failed")
        #expect(await peer.steps.count == steps.count)
    }

    /// A peer whose disk lacks room says so, naming the machine and what is free; a finish that
    /// fails cancels the upload there.
    @Test func aFullPeerDiskIsNamedAndAFailedFinishCancels() async throws {
        let peer = FakePeer(refuseBegin: AcpmuxRPCError(code: -32602, name: "filePut.noSpace", message: "full", freeBytes: 1_234_000_000))
        let target = AgentPeerUploads.Target(session: "s", machine: "huge-blue", host: peer)
        let stages = AgentUploadStages<AgentPeerUploads.Upload>(owner: "test") { _ in }
        let refused = await AgentPeerUploads.stage(.begin(name: "movie.mov", size: 5 << 30, batchToken: nil, batch: nil), target: target, stages: stages)
        #expect(Self.code(refused) == "no_space")
        let message = try #require((refused["error"] as? [String: Any])?["userMessage"] as? String, "\(refused)")
        let free = ByteCountFormatter.string(fromByteCount: 1_234_000_000, countStyle: .file)
        #expect(message.contains("huge-blue") && message.contains("movie.mov") && message.contains(free), "\(message)")
        #expect(stages.count == 0)

        let failing = FakePeer(refuseFinish: true)
        let other = AgentPeerUploads.Target(session: "s", machine: "huge-blue", host: failing)
        let begun = await AgentPeerUploads.stage(.begin(name: "a.bin", size: 0, batchToken: nil, batch: nil), target: other, stages: stages)
        let token = try #require((begun["value"] as? [String: Any])?["token"] as? String)
        let finished = await AgentPeerUploads.stage(.finish(token: token), target: other, stages: stages)
        #expect(Self.code(finished) == "upload_failed")
        #expect(await failing.steps.last == .cancel(upload: FakePeer.upload))
    }

    private static func code(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    /// A peer that records each streamed step and answers as acpmux does.
    private actor FakePeer: AgentPaneHostProviding {
        static let upload = "0190a000-0000-7000-8000-000000000000"
        private struct NoPage: Error {}
        private(set) var steps: [AgentPaneFilePutStep] = []
        private let refuseBegin: AcpmuxRPCError?
        private let refuseFinish: Bool

        init(refuseBegin: AcpmuxRPCError? = nil, refuseFinish: Bool = false) {
            self.refuseBegin = refuseBegin
            self.refuseFinish = refuseFinish
        }

        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw NoPage() }

        func putFile(sessionId: String, step: AgentPaneFilePutStep) async throws -> AgentPaneFilePutProgress {
            steps.append(step)
            switch step {
            case .begin:
                if let refuseBegin { throw AgentPaneFilePutFailure(refuseBegin) }
                return .begun(upload: Self.upload)
            case .chunk(_, let offset, let base64): return .wrote(offset: offset + (Data(base64Encoded: base64)?.count ?? 0))
            case .finish:
                if refuseFinish { throw AgentPaneFilePutFailure.failed }
                return .saved(path: "/home/me/.acpmux/uploads/s/x/a.bin")
            case .cancel: return .cancelled
            }
        }
    }
}
