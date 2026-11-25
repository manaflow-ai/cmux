import CmuxNextAgentPane
@testable import CmuxNextApp
import Darwin
import Foundation
import Testing

/// Leo, 2026-11-18: "dragging and dropping attachments of any size should never take time to load
/// ... Like, stop blocking." A file staged in 512 KiB chunks (`chat.upload.chunk`) is decoded and
/// written off the main thread: the page's request only hands the base64 text over, and the main
/// actor runs other work while each chunk is written.
@MainActor @Suite(.serialized)
struct AgentChatUploadChunksOffMainTests {
    private static func request(token: String, offset: Int, text: String) -> AgentPaneUploadStageRequest? {
        let request = AgentPaneRequest(body: ["method": "chat.upload.chunk", "params": ["token": token, "offset": offset, "data": text]])
        guard case .uploadStage(let stage) = request else { return nil }
        return stage
    }

    private static func begin(_ stage: AgentPaneUploadStager, size: Int) async throws -> String {
        let reply = await stage(.begin(name: "recording.mov", size: size, batchToken: nil, batch: nil), nil)
        let value = try #require(reply["value"] as? [String: Any])
        return try #require(value["token"] as? String)
    }

    /// The request leaves the chunk's bytes undecoded: text of a chunk's length that is not
    /// base64 is still a chunk request (its write then fails), so no decode ran on the main thread.
    @Test func theChunkRequestDoesNotDecodeItsBytes() {
        #expect(Self.request(token: "t", offset: 0, text: String(repeating: "*", count: 8)) != nil)
        #expect(Self.request(token: "t", offset: 0, text: Data([1, 2]).base64EncodedString()) != nil)
    }

    /// While a chunk is written, the main actor runs other work (the write waits on the files lane),
    /// and the file holds the chunk's bytes after.
    @Test func theMainActorRunsOtherWorkWhileAChunkIsWritten() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chunk-off-main-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = AgentChatUploads.stager(root: root, session: "new")
        let bytes = Data((0..<(512 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let token = try await Self.begin(stage, size: bytes.count)
        let chunk = try #require(Self.request(token: token, offset: 0, text: bytes.base64EncodedString()))
        var ranMeanwhile = false
        // task-owner: the test's probe of the main actor; it ends before the test does.
        let probe = Task { @MainActor in ranMeanwhile = true }
        let reply = await stage(chunk, nil)
        #expect(ranMeanwhile, "the chunk was decoded and written in one main-actor turn")
        #expect((reply["value"] as? [String: Any])?["offset"] as? Int == bytes.count, "\(reply)")
        await probe.value
        let finished = await stage(.finish(token: token), nil)
        let path = try #require((finished["value"] as? [String: Any])?["path"] as? String)
        #expect(try Data(contentsOf: URL(filePath: path)) == bytes)
    }

    /// The harness for the PR's numbers: the main thread's CPU time per 512 KiB chunk, from the page's
    /// request to its answer (decoding the request and staging the chunk), over 32 chunks.
    @Test func benchMainThreadTimePerChunk() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chunk-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = AgentChatUploads.stager(root: root, session: "new")
        let size = 512 * 1024, count = 32
        let text = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 131) }).base64EncodedString()
        let token = try await Self.begin(stage, size: size * count)
        var cpu: [Double] = [], wall: [Double] = []
        for index in 0..<count {
            let started = ContinuousClock.now
            // Only this test runs on the main thread meanwhile: its CPU time is the chunk's.
            let before = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let chunk = try #require(Self.request(token: token, offset: index * size, text: text))
            let reply = await stage(chunk, nil)
            let after = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let took = (ContinuousClock.now - started).components
            wall.append(Double(took.seconds) * 1000 + Double(took.attoseconds) / 1e15)
            cpu.append(Double(after - before) / 1e6)
            #expect((reply["value"] as? [String: Any])?["offset"] as? Int == (index + 1) * size, "\(reply)")
        }
        let sortedCPU = cpu.sorted(), sortedWall = wall.sorted()
        print("BENCH upload.chunk 512KiB main-thread cpu ms p50=\(sortedCPU[count / 2]) p90=\(sortedCPU[count * 9 / 10]) max=\(sortedCPU[count - 1]); wall ms p50=\(sortedWall[count / 2]) max=\(sortedWall[count - 1])")
        _ = await stage(.cancel(token: token), nil)
    }
}
