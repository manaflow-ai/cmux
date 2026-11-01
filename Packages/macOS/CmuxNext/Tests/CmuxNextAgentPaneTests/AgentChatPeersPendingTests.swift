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

    /// Review of #28083: the picker's peers come from this Mac's acpmux, whose status answers late
    /// under load. The list must end with the peers, not drop them (the peers call kept a 2 s
    /// deadline of its own after the lookup stopped having one).
    @Test func aRealAcpmuxThatAnswersLateEndsWithItsPeers() async throws {
        let root = URL(fileURLWithPath: "/tmp/apl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // An attached daemon (only read) served by this test process, so the peer check finds this
        // process's executable; every status answer comes 3 s late (past the old 2 s deadline).
        let environment = AcpmuxEnvironment(executable: try AcpmuxSlowDaemonTests.ownExecutable(), home: home,
                                            socketPath: home.appendingPathComponent("s.sock").path,
                                            daemonArguments: [], childEnvironment: [:]).attached(to: home)
        let daemon = try AcpmuxSlowDaemonTests.SlowDaemon(socketPath: environment.socketPath, home: home.path,
                                                          statusDelay: .seconds(3))
        defer { daemon.stop() }
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), resolve: { environment })
        let destinations = AgentChatDestinations(localTitle: "This Mac", peers: { try await host.chatPeers() },
                                                 cloud: { .init(signedIn: false, loaded: false, machines: []) })
        var lists = destinations.updates(peerBound: .milliseconds(200)).makeAsyncIterator()

        #expect(try #require(await lists.next()).map(\.id) == ["local", AgentChatDestinations.peersPendingID])
        let last = try #require(await lists.next())
        #expect(last.map(\.id) == ["local", "dev-box"], "the late peers were dropped: \(last.map(\.id))")
    }

    /// A peers request that fails is said, never shown as a Mac with no other Macs.
    @Test func aFailedPeerRequestShowsThatTheOtherMacsCouldNotBeLoaded() async throws {
        let destinations = AgentChatDestinations(localTitle: "This Mac", peers: { throw AgentPaneHostError.daemonStopped },
                                                 cloud: { .init(signedIn: false, loaded: false, machines: []) })
        var lists = destinations.updates(peerBound: .seconds(60)).makeAsyncIterator()
        #expect(try #require(await lists.next()).map(\.id) == ["local", AgentChatDestinations.peersFailedID])
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
/// to the end, then a write, let the later writer overwrite the earlier line). The interleaving is
/// forced, not left to timing: writer A has opened the log for its line when writer B writes its
/// whole line, then A writes.
nonisolated struct AcpmuxFailureLogConcurrentTests {
    @Test func aLineWrittenWhileAnotherWriterHoldsTheLogIsKept() throws {
        let root = URL(fileURLWithPath: "/tmp/afl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("daemon.log").path
        FileManager.default.createFile(atPath: path, contents: nil)
        // B's line is shorter than A's, so a write of A at B's start would cover it whole.
        let other = AcpmuxFailureLog(logPath: path)
        let person = AcpmuxFailureLog(logPath: path, beforeWrite: { other.record(.other, detail: "b") })

        #expect(person.record(.personRestart, detail: "pid 1"))
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        #expect(text.contains(AcpmuxFailureCause.other.logText), "writer B's line was overwritten: \(text)")
        #expect(text.contains(AcpmuxFailureCause.personRestart.logText), "writer A's line is missing: \(text)")
        #expect(text.split(separator: "\n").count == 2, "\(text)")
    }
}
