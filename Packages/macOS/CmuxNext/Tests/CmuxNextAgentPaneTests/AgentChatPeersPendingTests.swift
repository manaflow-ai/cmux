import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A limit that drops data shows the loss (R9, R-L5). The destination picker (palette, New Agent
/// Chat On) stops waiting for this Mac's acpmux to list its peers after a bound, so a slow acpmux
/// never holds the picker. Then it shows that the other Macs are not loaded yet, and the peers
/// when acpmux answers: the late reply is not dropped.
@MainActor @Suite(.serialized)
struct AgentChatPeersPendingTests {
    /// A peers reply that comes when `gate` opens.
    private static func destinations(gate: AsyncStream<Void>) -> AgentChatDestinations {
        AgentChatDestinations(localTitle: "This Mac", peers: {
            for await _ in gate { break }
            return [AgentChatPeer(name: "dev-box", isSSH: true, connected: true, state: "connected")]
        }, cloud: { .init(signedIn: false, loaded: false, machines: []) })
    }

    @Test func aPeerReplySlowerThanTheBoundShowsTheNoticeThenThePeers() async throws {
        let gate = AsyncStream.makeStream(of: Void.self)
        // The peers answer once the picker showed its first list, or after 10 s, so a picker that
        // shows nothing before every reply fails here instead of hanging.
        // task-owner: the fallback release; cancelled at the end
        let fallback = Task {
            try? await Task.sleep(for: .seconds(10))
            gate.continuation.yield()
        }
        defer { fallback.cancel() }
        var lists = Self.destinations(gate: gate.stream).updates(peerBound: .milliseconds(50)).makeAsyncIterator()

        let first = try #require(await lists.next())
        gate.continuation.yield()
        #expect(first.map(\.id) == ["local", AgentChatDestinations.peersPendingID],
                "a peer reply past the bound did not show that the other Macs are not loaded: \(first.map(\.id))")
        #expect(first.last?.isReady == false, "the notice row can be picked")
        let second = try #require(await lists.next(), "the late peers reply was dropped")
        #expect(second.map(\.id) == ["local", "dev-box"])
        #expect(await lists.next() == nil)
    }

    @Test func aPeerReplyWithinTheBoundShowsNoNotice() async throws {
        let destinations = AgentChatDestinations(localTitle: "This Mac", peers: {
            [AgentChatPeer(name: "dev-box", isSSH: true, connected: true, state: "connected")]
        }, cloud: { .init(signedIn: false, loaded: false, machines: []) })
        var lists = destinations.updates(peerBound: .seconds(60)).makeAsyncIterator()
        #expect(try #require(await lists.next()).map(\.id) == ["local", "dev-box"])
        #expect(await lists.next() == nil)
    }
}

/// Two writers of daemon.log at once keep both lines: a person's restart and the lookup that its
/// SIGTERM ends both write their cause at the same moment (green 79253da2c3e5c6f9c12e7344: a seek
/// to the end, then a write, let the later writer overwrite the earlier line).
nonisolated struct AcpmuxFailureLogConcurrentTests {
    @Test func twoRecordsAtOnceKeepBothLines() throws {
        let root = URL(fileURLWithPath: "/tmp/afl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for round in 0..<300 {
            let path = root.appendingPathComponent("daemon-\(round).log").path
            FileManager.default.createFile(atPath: path, contents: nil)
            let log = AcpmuxFailureLog(logPath: path)
            DispatchQueue.concurrentPerform(iterations: 2) { writer in
                log.record(writer == 0 ? .personRestart : .other, detail: "round \(round)")
            }
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let both = text.contains(AcpmuxFailureCause.personRestart.logText) && text.contains(AcpmuxFailureCause.other.logText)
            #expect(both, "round \(round) lost a line: \(text)")
            if !both { return }
        }
    }
}
