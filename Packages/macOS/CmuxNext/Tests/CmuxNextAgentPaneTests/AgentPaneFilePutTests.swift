import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A file dropped into a chat on an ssh peer goes through this Mac's acpmux to the peer
/// (`_acpmux/file_put`): only to an acpmux that says it takes files, and an older one here or on
/// the peer reads as "this chat takes no uploads".
struct AgentPaneFilePutTests {
    @Test func aFileIsSentOnlyAfterTheDaemonSaysItTakesFilesAndAnswersItsPathThere() async throws {
        let stream = Stream(chunks: [
            (1, Self.line(["id": 1, "result": ["_meta": ["acpmux": ["features": ["trustGate", "filePut"]]]]])),
            (2, Self.line(["id": 2, "result": ["path": "/home/me/.acpmux/uploads/s/1/state.sqlite", "peer": "huge-blue"]])),
        ])
        let path = try await AcpmuxStatusClient.putFile(sessionId: "s", name: "state.sqlite", data: Data([0, 1, 0xff])) { params in
            try await AcpmuxStatusClient.exchange(AcpmuxStatusClient.filePutMethod, params: params, transport: stream,
                                                  detailed: true, requiredFeature: AcpmuxStatusClient.filePutFeature)
        }
        #expect(path == "/home/me/.acpmux/uploads/s/1/state.sqlite")
        let sent = try Self.requests(await stream.writes())
        #expect(sent.map { $0["method"] as? String } == ["initialize", "_acpmux/file_put"])
        let params = try #require(sent.last?["params"] as? [String: String])
        #expect(params == ["sessionId": "s", "fileName": "state.sqlite", "data": Data([0, 1, 0xff]).base64EncodedString()])
    }

    @Test func anOlderAcpmuxHereOrOnThePeerTakesNoFiles() async throws {
        // This Mac's acpmux predates the method: the bytes never go.
        let older = Stream(chunks: [(1, Self.line(["id": 1, "result": ["_meta": ["acpmux": ["features": ["trustGate"]]]]]))])
        await #expect(throws: AgentPaneFilePutFailure.unsupported) {
            try await AcpmuxStatusClient.putFile(sessionId: "s", name: "a.txt", data: Data("x".utf8)) { params in
                try await AcpmuxStatusClient.exchange(AcpmuxStatusClient.filePutMethod, params: params, transport: older,
                                                      detailed: true, requiredFeature: AcpmuxStatusClient.filePutFeature)
            }
        }
        #expect(try Self.requests(await older.writes()).map { $0["method"] as? String } == ["initialize"])
        // This Mac's takes files, the peer's does not.
        let peer = Stream(chunks: [
            (1, Self.line(["id": 1, "result": ["_meta": ["acpmux": ["features": ["filePut"]]]]])),
            (2, Self.line(["id": 2, "error": ["code": -32601, "message": "Method not found: _acpmux/file_put",
                                              "data": ["reason": "filePut.unsupported"]]])),
        ])
        await #expect(throws: AgentPaneFilePutFailure.unsupported) {
            try await AcpmuxStatusClient.putFile(sessionId: "s", name: "a.txt", data: Data("x".utf8)) { params in
                try await AcpmuxStatusClient.exchange(AcpmuxStatusClient.filePutMethod, params: params, transport: peer,
                                                      detailed: true, requiredFeature: AcpmuxStatusClient.filePutFeature)
            }
        }
    }

    @Test func refusalsMapToWhatTheComposerSays() {
        #expect(AgentPaneFilePutFailure(AcpmuxRPCError(code: -32601, message: "Method not found")) == .unsupported)
        #expect(AgentPaneFilePutFailure(AcpmuxRPCError(code: -32602, name: "filePut.tooLarge", message: "big")) == .tooLarge)
        #expect(AgentPaneFilePutFailure(AcpmuxRPCError(code: -32602, name: "filePut.name", message: "name")) == .failed)
        #expect(AgentPaneFilePutFailure(AcpmuxStatusClient.Failure.unsupportedFeature("filePut")) == .unsupported)
        #expect(AgentPaneFilePutFailure(AcpmuxStatusClient.Failure.unreachable("no daemon")) == .failed)
    }

    @Test func resumableUploadUsesBoundedChunksAndCommitsThePath() async throws {
        let data = Data(repeating: 7, count: AcpmuxStatusClient.filePutChunkBytes * 2 + 3)
        let calls = CallLog()
        let path = try await AcpmuxStatusClient.putFileChunked(sessionId: "s", name: "big.bin", data: data) { method, params in
            await calls.add(method)
            switch method {
            case AcpmuxStatusClient.filePutBeginMethod: return ["uploadId": "0190a000-0000-7000-8000-000000000000"]
            case AcpmuxStatusClient.filePutChunkMethod:
                let offset = params["offset"] as? Int ?? 0
                let bytes = Data(base64Encoded: params["data"] as? String ?? "")?.count ?? 0
                return ["offset": offset + bytes]
            default: return ["path": "/uploads/s/big.bin"]
            }
        }
        #expect(path == "/uploads/s/big.bin")
        let methods = await calls.methods()
        #expect(methods == ["_acpmux/file_put_begin", "_acpmux/file_put_chunk", "_acpmux/file_put_chunk", "_acpmux/file_put_chunk", "_acpmux/file_put_finish"])
    }

    /// Review of #27012 (P2): a chunked put cancelled while its finish was pending (the page's x on
    /// a dictation upload to a peer) sent its `file_put_cancel` from the cancelled task, whose call
    /// is torn down at once, so the peer kept the upload it staged. The cleanup now runs in a fresh
    /// task that is not cancelled.
    @Test func aPutCancelledDuringItsFinishCleansUpFromATaskThatIsNotCancelled() async throws {
        let data = Data(repeating: 7, count: AcpmuxStatusClient.filePutChunkBytes + 3)
        let calls = CallLog()
        let put = Task {
            try await AcpmuxStatusClient.putFileChunked(sessionId: "s", name: "big.bin", data: data) { method, params in
                await calls.add(method, cancelled: Task.isCancelled)
                switch method {
                case AcpmuxStatusClient.filePutBeginMethod: return ["uploadId": "0190a000-0000-7000-8000-000000000000"]
                case AcpmuxStatusClient.filePutChunkMethod:
                    let offset = params["offset"] as? Int ?? 0
                    let bytes = Data(base64Encoded: params["data"] as? String ?? "")?.count ?? 0
                    return ["offset": offset + bytes]
                case AcpmuxStatusClient.filePutFinishMethod:
                    // The peer's transfer is in flight until the call is torn down.
                    try await Task.sleep(for: .seconds(600))
                    return ["path": "/uploads/s/big.bin"]
                default: return [:]
                }
            }
        }
        for _ in 0..<300 {
            if await calls.methods().contains(AcpmuxStatusClient.filePutFinishMethod) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        put.cancel()
        let result = await put.result
        #expect((try? result.get()) == nil, "a cancelled put answers no path")
        let entries = await calls.entries
        let cancels = entries.filter { $0.method == AcpmuxStatusClient.filePutCancelMethod }
        #expect(cancels.count == 1, "the staged upload is cancelled on the peer")
        #expect(cancels.allSatisfy { !$0.cancelled }, "the cleanup ran in a task that was not cancelled")
    }

    @Test func aHostWithoutAnAcpmuxTakesNoFiles() async {
        await #expect(throws: AgentPaneFilePutFailure.unsupported) {
            try await MockAgentPaneHost().putFile(sessionId: "s", name: "a.txt", data: Data("x".utf8))
        }
    }

    private static func requests(_ payloads: [Data]) throws -> [[String: Any]] {
        try payloads.flatMap { payload in
            try payload.split(separator: 0x0A).map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] ?? [:] }
        }
    }

    private static func line(_ object: [String: Any]) -> Data {
        // Fixtures contain only Foundation JSON values.
        (try? JSONSerialization.data(withJSONObject: object)).map { $0 + Data([0x0A]) } ?? Data()
    }

    private actor Stream: AcpmuxRPCTransport {
        private var chunks: [(writes: Int, data: Data)]
        private var sent: [Data] = []
        init(chunks: [(Int, Data)]) { self.chunks = chunks }
        func start() async throws {}
        func send(_ data: Data) async throws { sent.append(data) }
        func receive() async throws -> Data? {
            guard !chunks.isEmpty else { return nil }
            let next = chunks.removeFirst()
            #expect(sent.count == next.writes, "the file went before the feature handshake")
            return next.data
        }
        func writes() -> [Data] { sent }
    }

    private actor CallLog {
        var entries: [(method: String, cancelled: Bool)] = []
        func add(_ method: String, cancelled: Bool = false) { entries.append((method, cancelled)) }
        func methods() -> [String] { entries.map(\.method) }
    }
}
