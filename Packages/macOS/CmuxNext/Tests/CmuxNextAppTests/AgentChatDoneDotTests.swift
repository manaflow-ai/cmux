import CmuxNextAgentLanes
import CmuxNextBridge
@testable import CmuxNextDaemon
import Darwin
import Foundation
import os
import Testing
@testable import CmuxNextApp

/// acpmux owns what the person has seen of an agent chat (cx-n8ou): a turn
/// that ends while no pane shows the chat leaves it `unread`, and a pane
/// that shows it clears that, in any window or app. The chat tab's done dot
/// follows acpmux's `unread`. Each test runs the app's turn-state feed
/// against a stand-in acpmux on a real socket and reads the tab's status.
@MainActor
@Suite(.serialized)
struct AgentChatDoneDotTests {
    static let host = "install:done-dot"

    /// A chat tab of `session` on this Mac.
    static func chatTab(_ session: String) -> TabModel {
        var snapshot = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .conversation, cwd: nil)
        snapshot.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session, harness: "codex"))
        return TabModel(snapshot)
    }

    /// One session summary as acpmux sends it: its last turn completed.
    static func summary(_ session: String, turn: String, unread: Bool) -> [String: Any] {
        ["sessionId": session, "status": "idle", "indicator": "done", "unread": unread,
         "lastTurn": ["turnId": turn, "status": "completed"]]
    }

    @Test func aChatShownInAnyPaneLosesItsDoneDot() async throws {
        let acpmux = try StandInAcpmux(sessions: [Self.summary("s1", turn: "t1", unread: true)])
        let turns = AgentTurnStateStore()
        let feed = AgentTurnStateFeed(socketPath: acpmux.path, turns: turns)
        feed.start(localHost: Self.host)
        let mapping = StatusMapping(turns: turns, seen: ProgramStatusSeenStore())
        let tab = Self.chatTab("s1")
        try await until { mapping.visibleTurn(tab) != nil }
        #expect(mapping.visibleTurn(tab) != nil, "a turn that ended unseen shows its done dot")

        // A pane showed the chat (here, or in another window or app): acpmux clears `unread`.
        acpmux.push(Self.summary("s1", turn: "t1", unread: false))
        try await until { mapping.visibleTurn(tab) == nil }
        #expect(mapping.visibleTurn(tab) == nil, "a chat a pane has shown has no done dot")

        // The next turn ends while no pane shows it.
        acpmux.push(Self.summary("s1", turn: "t2", unread: true))
        try await until { mapping.visibleTurn(tab) != nil }
        #expect(mapping.visibleTurn(tab) != nil, "a later turn that ends unseen shows the dot again")
        withExtendedLifetime((acpmux, feed)) {}
    }

    @Test func aChatSeenBeforeTheAppConnectedHasNoDoneDot() async throws {
        let acpmux = try StandInAcpmux(sessions: [Self.summary("s2", turn: "t1", unread: false),
                                                  Self.summary("s3", turn: "t1", unread: true)])
        let turns = AgentTurnStateStore()
        let feed = AgentTurnStateFeed(socketPath: acpmux.path, turns: turns)
        feed.start(localHost: Self.host)
        let mapping = StatusMapping(turns: turns, seen: ProgramStatusSeenStore())
        try await until { mapping.visibleTurn(Self.chatTab("s3")) != nil }
        #expect(mapping.visibleTurn(Self.chatTab("s2")) == nil)
        #expect(mapping.visibleTurn(Self.chatTab("s3")) != nil)
        withExtendedLifetime((acpmux, feed)) {}
    }

    /// Waits up to five seconds for `done`.
    private func until(_ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }
}

/// A stand-in acpmux on a unix socket: answers the app's `initialize` and
/// `_acpmux/watch` with `sessions`, then sends `_acpmux/session_changed` on
/// `push`. One client.
nonisolated final class StandInAcpmux {
    let path: String
    private let listener: Int32
    /// The accepted connection, -1 until the app connects.
    private let client = OSAllocatedUnfairLock(initialState: Int32(-1))
    private let connected = DispatchSemaphore(value: 0)

    init(sessions: [[String: Any]]) throws {
        path = "/tmp/cmux-done-dot-\(getpid())-\(UInt32.random(in: 0 ... .max)).sock"
        unlink(path)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        listener = server
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(server, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
        let page = Self.line(["jsonrpc": "2.0", "id": 2, "result": ["sessions": sessions]])
        let initialized = Self.line(["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": 1]])
        let client = client, connected = connected
        Thread.detachNewThread {
            let fd = accept(server, nil, nil)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Both requests arrive at once; answer once the watch is in.
            var seen = 0
            var byte: UInt8 = 0
            while seen < 2, read(fd, &byte, 1) == 1 { if byte == 0x0A { seen += 1 } }
            Self.write(fd, initialized + page)
            client.withLock { $0 = fd }
            connected.signal()
        }
    }

    deinit {
        close(listener)
        client.withLock { if $0 >= 0 { close($0) } }
        unlink(path)
    }

    /// One `_acpmux/session_changed` with the session's new summary.
    func push(_ summary: [String: Any]) {
        push(params: ["sessionId": summary["sessionId"] ?? "", "session": summary])
    }

    /// One `_acpmux/session_changed` with these params.
    func push(params: [String: Any]) {
        if connected.wait(timeout: .now() + 5) == .success { connected.signal() }
        let fd = client.withLock { $0 }
        guard fd >= 0 else { return }
        Self.write(fd, Self.line(["jsonrpc": "2.0", "method": "_acpmux/session_changed", "params": params]))
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }

    private static func write(_ fd: Int32, _ data: Data) {
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}
