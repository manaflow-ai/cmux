import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextWakeups
import Darwin
import Foundation
import os
import Testing
@testable import CmuxNextApp

/// Mute one agent chat's notifications (cx-sg1qz): the tab menu's Mute Chat
/// Notifications sets the chat's acpmux tag `notifications: muted`, which the
/// cmux-tui daemon honors (it posts nothing for the chat) on every window and
/// device, and the menu reads the mute back from acpmux. Each test runs the
/// app's turn-state watch and the mute against a stand-in acpmux on a real
/// socket that keeps tags as acpmux does.
@MainActor
@Suite(.serialized)
struct AgentChatMuteTests {
    static let host = "install:chat-mute"

    static func chat(_ session: String, host: String = host) -> AgentSessionRef {
        AgentSessionRef(host: host, session: session, harness: "codex")
    }

    // The public resolve: a DEBUG build honors an exported CMUX_NEXT_ACPMUX_BIN here, which only
    // changes `executable`. These tests talk to a fake socket and never check the executable.
    static func environment(_ acpmux: TaggingAcpmux) throws -> AcpmuxEnvironment {
        try #require(AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: nil,
                                               environment: ["ACPMUX_SOCKET": acpmux.path, "ACPMUX_HOME": "/tmp"],
                                               isExecutable: { _ in true }))
    }

    @Test func muteSetsTheChatsAcpmuxTagAndUnmuteRemovesIt() async throws {
        let acpmux = try TaggingAcpmux(sessions: ["s1": [:]])
        let turns = AgentTurnStateStore()
        let feed = AgentTurnStateFeed(socketPath: acpmux.path, turns: turns, deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())))
        feed.start(localHost: Self.host)
        let mute = AgentChatMute(environment: try Self.environment(acpmux), turns: turns)
        try await until { turns.isMuted(Self.chat("s1")) != nil && acpmux.watching }
        #expect(mute.isMuted(Self.chat("s1")) == false)

        #expect(try await mute.toggle(Self.chat("s1")))
        try await until { mute.isMuted(Self.chat("s1")) == true }
        #expect(acpmux.tags("s1") == ["notifications": "muted"], "acpmux holds the mute")
        #expect(mute.isMuted(Self.chat("s1")) == true, "the menu reads Unmute")

        #expect(try await mute.toggle(Self.chat("s1")))
        try await until { mute.isMuted(Self.chat("s1")) == false }
        #expect(acpmux.tags("s1") == [:], "unmute removes the tag")
        #expect(mute.isMuted(Self.chat("s1")) == false)
        withExtendedLifetime((acpmux, feed)) {}
    }

    @Test func aChatMutedElsewhereReadsMutedAndAnotherMacsChatIsLeftAlone() async throws {
        let acpmux = try TaggingAcpmux(sessions: ["s2": ["notifications": "muted"], "s3": [:]])
        let turns = AgentTurnStateStore()
        let feed = AgentTurnStateFeed(socketPath: acpmux.path, turns: turns, deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())))
        feed.start(localHost: Self.host)
        let mute = AgentChatMute(environment: try Self.environment(acpmux), turns: turns)
        try await until { mute.isMuted(Self.chat("s2")) == true }
        #expect(mute.isMuted(Self.chat("s2")) == true, "muted from another window or device")
        #expect(mute.isMuted(Self.chat("s3")) == false)

        // Another Mac's acpmux runs that chat: this Mac neither reads nor writes its mute.
        let elsewhere = Self.chat("s3", host: "install:other-mac")
        #expect(mute.isMuted(elsewhere) == nil)
        #expect(try await mute.toggle(elsewhere) == false)
        #expect(acpmux.tags("s3") == [:])
        withExtendedLifetime((acpmux, feed)) {}
    }

    /// Waits up to five seconds for `done`.
    private func until(_ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }
}

/// A stand-in acpmux on a unix socket that keeps each session's tags. Every
/// connection sends `initialize` and one request: `_acpmux/watch` gets the
/// sessions and stays open for `_acpmux/session_changed`; `_acpmux/tag` sets
/// and removes tags, answers with the summary and tells the watch, as
/// acpmux does.
nonisolated final class TaggingAcpmux {
    let path: String
    private let listener: Int32
    private struct State: Sendable {
        var tags: [String: [String: String]]
        /// More fields of each session's summary (`title`, `name`, `lastPrompt`).
        var fields: [String: [String: String]] = [:]
        var watcher: Int32 = -1
        var connections: [Int32] = []
    }
    private let state: OSAllocatedUnfairLock<State>

    init(sessions: [String: [String: String]], fields: [String: [String: String]] = [:]) throws {
        path = "/tmp/cmux-chat-mute-\(getpid())-\(UInt32.random(in: 0 ... .max)).sock"
        unlink(path)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        listener = server
        state = OSAllocatedUnfairLock(initialState: State(tags: sessions, fields: fields))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(server, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        let state = state
        Thread.detachNewThread {
            while true {
                let fd = accept(server, nil, nil)
                guard fd >= 0 else { return }
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                state.withLock { $0.connections.append(fd) }
                Thread.detachNewThread { Self.serve(fd, state: state) }
            }
        }
    }

    deinit {
        close(listener)
        state.withLock { $0.connections.forEach { close($0) } }
        unlink(path)
    }

    var watching: Bool { state.withLock { $0.watcher >= 0 } }

    func tags(_ session: String) -> [String: String] { state.withLock { $0.tags[session] ?? [:] } }

    private static func serve(_ fd: Int32, state: OSAllocatedUnfairLock<State>) {
        var lines: [Data] = []
        var current = Data()
        var byte: UInt8 = 0
        while lines.count < 2, read(fd, &byte, 1) == 1 {
            if byte == 0x0A { lines.append(current); current = Data() } else { current.append(byte) }
        }
        guard lines.count == 2, let request = try? JSONSerialization.jsonObject(with: lines[1]) as? [String: Any] else { return }
        let initialized = line(["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": 1]])
        let params = request["params"] as? [String: Any] ?? [:]
        switch request["method"] as? String {
        case "_acpmux/watch":
            let (tags, fields) = state.withLock { ($0.tags, $0.fields) }
            let page = tags.keys.sorted().map { summary($0, tags: tags[$0] ?? [:], fields: fields[$0] ?? [:]) }
            write(fd, initialized + line(["jsonrpc": "2.0", "id": 2, "result": ["sessions": page]]))
            state.withLock { $0.watcher = fd }
        case "_acpmux/tag":
            let session = params["sessionId"] as? String ?? ""
            let set = params["set"] as? [String: String] ?? [:], remove = params["remove"] as? [String] ?? []
            let (tags, fields, watcher) = state.withLock { current -> ([String: String], [String: String], Int32) in
                var tags = current.tags[session] ?? [:]
                for (key, value) in set { tags[key] = value }
                for key in remove { tags.removeValue(forKey: key) }
                current.tags[session] = tags
                return (tags, current.fields[session] ?? [:], current.watcher)
            }
            let changed = summary(session, tags: tags, fields: fields)
            write(fd, initialized + line(["jsonrpc": "2.0", "id": 2, "result": changed]))
            if watcher >= 0 {
                write(watcher, line(["jsonrpc": "2.0", "method": "_acpmux/session_changed",
                                     "params": ["sessionId": session, "session": changed, "kind": "tags"]]))
            }
        default:
            write(fd, initialized + line(["jsonrpc": "2.0", "id": 2, "error": ["code": -32601, "message": "no such method"]]))
        }
    }

    private static func summary(_ session: String, tags: [String: String], fields: [String: String]) -> [String: Any] {
        let summary: [String: Any] = ["sessionId": session, "status": "idle", "indicator": "done", "unread": false, "tags": tags]
        return summary.merging(fields) { current, _ in current }
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
