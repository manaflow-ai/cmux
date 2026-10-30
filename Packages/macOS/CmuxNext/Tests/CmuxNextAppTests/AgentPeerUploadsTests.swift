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

    /// A file past the former 1 GiB peer limit is sent; its bytes are declared (`Data(count:)`, zero
    /// pages never touched), not written.
    @Test func anInlinePeerUploadOfAnySizeIsSent() async throws {
        let size = (1 << 30) + 1
        var sent: [Int] = []
        let reply = await AgentPeerUploads.upload([AgentPaneUpload(name: "recording.mov", data: Data(count: size))], machine: "huge-blue") { _, data in
            sent.append(data.count)
            return "/home/me/.acpmux/uploads/s/1/recording.mov"
        }
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        #expect(sent == [size])
    }

    /// A staged begin past the former 1 GiB peer limit is taken, on its own and as a batch's first
    /// file; the stage is an empty file until chunks come, and is cancelled here.
    @Test(arguments: [(1 << 30) + 1, 8 << 30])
    func aStagedPeerBeginOfAnySizeIsTaken(size: Int) async throws {
        try await Self.withPeerStager { stager, session in
            let batches: [[AgentPaneUploadBatchEntry]?] = [nil, [AgentPaneUploadBatchEntry(name: "big.bin", size: size),
                                                                 AgentPaneUploadBatchEntry(name: "next.bin", size: size)]]
            for batch in batches {
                let reply = await stager(.begin(name: "big.bin", size: size, batchToken: nil, batch: batch), session)
                #expect(reply["ok"] as? Bool == true, "\(reply)")
                let token = try #require((reply["value"] as? [String: Any])?["token"] as? String)
                _ = await stager(.cancel(token: token), session)
            }
        }
    }

    /// A batch past the former 1 GiB total, of files each under it, is taken.
    @Test func aStagedPeerBatchPastTheFormerTotalIsTaken() async throws {
        let part = 600 * 1024 * 1024
        try await Self.withPeerStager { stager, session in
            let batch = [AgentPaneUploadBatchEntry(name: "a.mov", size: part), AgentPaneUploadBatchEntry(name: "b.mov", size: part)]
            let reply = await stager(.begin(name: "a.mov", size: part, batchToken: nil, batch: batch), session)
            #expect(reply["ok"] as? Bool == true, "\(reply)")
            let value = try #require(reply["value"] as? [String: Any])
            #expect(value["batchToken"] is String)
            let token = try #require(value["token"] as? String)
            _ = await stager(.cancel(token: token), session)
        }
    }

    /// A cancellation while the peer is reading the staged file cancels the transfer first, then
    /// removes the stage. The host never observes a path whose file was already unlinked.
    @Test func cancellingAStagedPeerFinishWaitsForTransferCleanup() async throws {
        let host = SlowPeerUploadHost()
        try await Self.withPeerStager(host: host) { stager, session in
            let reply = await stager(.begin(name: "slow.bin", size: 1, batchToken: nil, batch: nil), session)
            let token = try #require((reply["value"] as? [String: Any])?["token"] as? String)
            _ = await stager(.chunk(token: token, offset: 0, data: Data([1])), session)
            let finishing = Task { @MainActor in _ = await stager(.finish(token: token), session) }
            let staged = await host.waitForFile()
            #expect(FileManager.default.fileExists(atPath: staged.path))
            _ = await stager(.cancel(token: token), session)
            #expect(!FileManager.default.fileExists(atPath: staged.path))
            _ = await finishing.value
        }
    }

    /// The page's begin past the former 1 GiB decoder limit, alone or with a batch naming a file past
    /// it, decodes as the bridge decodes it (``DecodedStagedBegins``) and the peer stager takes it.
    @Test(arguments: [2 << 30, 8 << 30])
    func aDecodedBeginOfAnySizeReachesThePeerStager(size: Int) async throws {
        try await Self.withPeerStager { stager, session in
            for (params, begin) in DecodedStagedBegins.cases(size: size) {
                let stage = try #require(DecodedStagedBegins.decode(params), "the decoder refused \(params)")
                #expect(stage == begin)
                let reply = await stager(stage, session)
                #expect(reply["ok"] as? Bool == true, "\(reply)")
                let token = try #require((reply["value"] as? [String: Any])?["token"] as? String)
                _ = await stager(.cancel(token: token), session)
            }
        }
    }

    /// The peer stager of a tab whose chat runs on `huge-blue`, and that chat's session.
    private static func withPeerStager(host: (any AgentPaneHostProviding)? = nil,
                                       _ body: @escaping (_ stager: @escaping AgentPaneUploadStager, _ session: String) async throws -> Void) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let tab = "tab-\(UUID().uuidString)", session = "peer-\(UUID().uuidString)"
        services.agentTabs.gitLink = { _ in services.agentGit.local }
        services.agentTabs.localSessionHost = host
        services.agentTabs.sessions[tab] = session
        AgentLaneStore.shared.lanes[session] = AgentActivityLane(id: session, name: "huge-blue/fix", title: "fix", peer: "huge-blue",
                                                                 parent: nil, state: .idle, since: nil, error: nil)
        defer { AgentLaneStore.shared.lanes[session] = nil }
        let stager = try #require(AgentPeerUploads.stager(tab: tab, services: services))
        try await body(stager, session)
    }

    private static func code(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }
}

private actor SlowPeerUploadHost: AgentPaneHostProviding {
    private var startedFile: URL?
    private var waiters: [CheckedContinuation<URL, Never>] = []

    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }

    func putFile(sessionId: String, name: String, file: URL) async throws -> String {
        startedFile = file
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: file) }
        try await Task.sleep(for: .seconds(3_600))
        return "/home/peer/\(name)"
    }

    func waitForFile() async -> URL {
        if let startedFile { return startedFile }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
