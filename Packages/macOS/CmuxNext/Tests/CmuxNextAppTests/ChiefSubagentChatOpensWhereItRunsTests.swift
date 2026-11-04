import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextHomeEngine
import CmuxNextWakeups

/// #27934 (cmux NEXT NIGHTLY, 2026-10-30): the workspace a named Chief's spawn tool made for its
/// subagent a95 ("Chief deeplinks broken launcher") said "Can't find this chat" while the session
/// ran. The named Chief (`<home>/c/<id>`) runs its subagents in its home's acpmux, tagged with its
/// own `mux.parent` (`optchat-chief:<named id>`), and the spawn tool opens their workspaces with no
/// host, so each tab records this Mac's. The tab's router asked the Chief home's acpmux only for a
/// session tagged with the home's own Chief: the live daemon listed a95 under another tag, so the
/// tab went to this Mac's acpmux, which lacks it. A session the Chief home's acpmux runs attaches
/// there whatever its tag (a named Chief's, none for a subagent's `acpmux new` chat); a session it
/// does not run, or only mirrors from a peer, stays on this Mac's.
@Suite(.serialized) struct ChiefSubagentChatOpensWhereItRunsTests {
    private struct Reached: Error {
        let host: String
    }

    /// A pane host that only says it was reached.
    private struct NamedHost: AgentPaneHostProviding {
        let name: String
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw Reached(host: name) }
        func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? { nil }
        func putFile(sessionId: String, name: String, data: Data) async throws -> String { "" }
    }

    private func reached(_ host: (any AgentPaneHostProviding)?, session: String) async -> String? {
        guard let host else { return nil }
        do {
            _ = try await host.handshake(sessionId: session)
            return nil
        } catch let reached as Reached {
            return reached.host
        } catch {
            return nil
        }
    }

    /// The named Chief's subagent (a95), tagged with the named Chief's home id, not the home's.
    private let namedChiefSubagent = "01a19008-7a62-72f3-91b5-abbaec0e76f0"
    /// A chat a subagent started with `acpmux new` in the Chief home's acpmux: no `mux.parent`.
    private let untagged = "01a19008-2de3-7813-9429-d96bf8fe6144"
    /// The home's own Chief's subagent, tagged with the home's id.
    private let ownSubagent = "01a19008-b675-7273-aba8-0668fef760fa"
    /// A row the Chief home's acpmux mirrors from a peer machine.
    private let peerRow = "01a19008-c465-7a33-9017-7effe7b26230"
    /// An ordinary chat of this Mac's acpmux.
    private let appChat = "01a1610c-24e0-75a3-8440-e4bcf537a4ba"

    private func rows(homeTag: String, namedTag: String) -> [String: [String: Any]] {
        [
            namedChiefSubagent: ["sessionId": namedChiefSubagent, "tags": ["mux.parent": namedTag, "mux.handle": "a95"]],
            untagged: ["sessionId": untagged, "tags": [String: String]()],
            ownSubagent: ["sessionId": ownSubagent, "tags": ["mux.parent": homeTag]],
            peerRow: ["sessionId": peerRow, "peer": "gcp", "tags": ["mux.parent": namedTag]],
        ]
    }

    /// The tab of a Chief subagent that records this Mac's host (the spawn tool sends none) goes
    /// through the router the app's Chief home gives this Mac's tabs (``ChiefHomeAcpmux/localRouter``).
    @Test func aSubagentTabRecordedOnThisMacAttachesWhereTheChiefHomesAcpmuxRunsIt() async throws {
        let daemon = try FakeChiefAcpmux(sessions: rows(homeTag: "optchat-chief:b902d10e", namedTag: "optchat-chief:69e026c6"))
        defer { daemon.stop() }
        let router = AcpmuxChiefSessionRouter(local: NamedHost(name: "app"), chief: NamedHost(name: "chief-home"),
                                              chiefEnvironment: daemon.environment)

        #expect(await reached(router, session: namedChiefSubagent) == "chief-home")
        #expect(await reached(router, session: untagged) == "chief-home")
        #expect(await reached(router, session: ownSubagent) == "chief-home")
        // Never another machine's row, never a chat the Chief home's acpmux does not run.
        #expect(await reached(router, session: peerRow) == "app")
        #expect(await reached(router, session: appChat) == "app")
        // Each answer is the daemon's exact resolve of that one session, never a page of its list.
        #expect(daemon.methods.allSatisfy { $0 == "initialize" || $0 == "_acpmux/resolve" }, "\(daemon.methods)")
    }

    /// A tab that names the named Chief's own host (`chief:<named id>`) reaches the same daemon
    /// through the Chief home directory (#27712), and its home's other sessions open there too.
    @Test func aNamedChiefsTabAttachesToItsHomesAcpmux() async throws {
        let base = URL(fileURLWithPath: "/tmp/cx27934-\(UUID().uuidString.prefix(6).lowercased())/chief", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        let home = base.appendingPathComponent("default", isDirectory: true)
        let named = home.appendingPathComponent("c/dbh2607j", isDirectory: true)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        let homeHost = ChiefHomeAcpmux.host(muxHome: home), namedHost = ChiefHomeAcpmux.host(muxHome: named)
        let daemon = try FakeChiefAcpmux(socket: home.appendingPathComponent("acpmux/acpmux.sock").path,
                                         sessions: rows(homeTag: "optchat-chief:" + homeHost.dropFirst("chief:".count),
                                                        namedTag: "optchat-chief:" + namedHost.dropFirst("chief:".count)))
        defer { daemon.stop() }
        let environment = daemon.environment
        let directory = ChiefHomeDirectory(parents: [base], work: BackgroundWork(), environment: { owner in
            owner.acpmuxHome.standardizedFileURL.path == environment.home.standardizedFileURL.path ? environment : nil
        }) { _, starts in NamedHost(name: starts ? "chief-home, started" : "chief-home") }

        let tab = ChiefHomeSessionHost(host: namedHost, homes: directory, fallback: NamedHost(name: "app"))
        #expect(await reached(tab, session: namedChiefSubagent) == "chief-home, started")
        #expect(await reached(tab, session: untagged) == "chief-home, started")
        #expect(await reached(tab, session: appChat) == "app")
    }

    /// The Chief home's acpmux is stopped (no socket): only a session its home keeps on disk opens
    /// there; anything else is this Mac's.
    @Test func aStoppedChiefHomesAcpmuxStillOpensTheChatsItKeeps() async throws {
        let root = URL(fileURLWithPath: "/tmp/cx27934-\(UUID().uuidString.prefix(6).lowercased())/acpmux", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions/\(namedChiefSubagent)", isDirectory: true),
                                                withIntermediateDirectories: true)
        let environment = FakeChiefAcpmux.environment(home: root, socket: root.appendingPathComponent("acpmux.sock").path)
        let router = AcpmuxChiefSessionRouter(local: NamedHost(name: "app"), chief: NamedHost(name: "chief-home"),
                                              chiefEnvironment: environment)
        #expect(await reached(router, session: namedChiefSubagent) == "chief-home")
        #expect(await reached(router, session: appChat) == "app")
    }
}

/// acpmux on a unix socket that answers `initialize`, `_acpmux/sessions` (every row of `sessions` on
/// one page) and the exact `_acpmux/resolve` of `sessions` (`-32002` for any other id), one JSON-RPC object per line, each connection on its own thread.
nonisolated final class FakeChiefAcpmux: @unchecked Sendable { // crash-allow: the log is read and written under `lock`
    private let lock = NSLock()
    private let listener: Int32
    private let sessions: [String: [String: Any]]
    private var log: [String] = []
    private var stopped = false
    let socket: String
    let ownsDirectory: Bool

    var methods: [String] { lock.withLock { log } }

    var environment: AcpmuxEnvironment {
        Self.environment(home: URL(fileURLWithPath: (socket as NSString).deletingLastPathComponent, isDirectory: true), socket: socket)
    }

    static func environment(home: URL, socket: String) -> AcpmuxEnvironment {
        AcpmuxEnvironment(executable: URL(fileURLWithPath: "/usr/bin/false"), home: home, socketPath: socket,
                          daemonArguments: [], childEnvironment: [:])
    }

    /// - Parameter socket: where it listens; a new short directory under `/tmp` by default (a unix
    ///   socket path fits in 104 bytes).
    init(socket: String? = nil, sessions: [String: [String: Any]]) throws {
        ownsDirectory = socket == nil
        self.socket = socket ?? "/tmp/cx27934-\(UUID().uuidString.prefix(8).lowercased())/acpmux.sock"
        self.sessions = sessions
        try FileManager.default.createDirectory(atPath: (self.socket as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(self.socket.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in path.withUnsafeBytes { buffer.copyMemory(from: $0) } }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        listener = fd
        Thread.detachNewThread { [self] in accept() }
    }

    /// The accept thread closes the listener once it sees the stop, so no fd number it still polls
    /// is reused by another test in between.
    func stop() {
        lock.withLock { stopped = true }
        if ownsDirectory { try? FileManager.default.removeItem(atPath: (socket as NSString).deletingLastPathComponent) }
    }

    /// Accepts until ``stop()``; each wait is bounded so a stop is seen.
    private func accept() {
        defer { close(listener) }
        while !lock.withLock({ stopped }) {
            var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 200) >= 0 else { return }
            guard waiting.revents & Int16(POLLIN) != 0 else { continue }
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            Thread.detachNewThread { [self] in serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let id = request["id"], let method = request["method"] as? String else { continue }
                let params = request["params"] as? [String: Any] ?? [:]
                lock.withLock { log.append(method) }
                var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
                switch method {
                case "initialize":
                    reply["result"] = ["_meta": ["acpmux": ["capabilities": ["acpmux-v1"]]]]
                case "_acpmux/resolve" where params["exactSessionId"] as? Bool == true:
                    if let row = sessions[params["sessionId"] as? String ?? ""] {
                        reply["result"] = ["session": row]
                    } else {
                        reply["error"] = ["code": -32002, "message": "no such session"] as [String: Any]
                    }
                case "_acpmux/sessions":
                    // One page with every row, as the daemon lists them.
                    reply["result"] = ["sessions": Array(sessions.values)]
                default:
                    reply["error"] = ["code": -32601, "message": "method not found"] as [String: Any]
                }
                guard var frame = try? JSONSerialization.data(withJSONObject: reply) else { return }
                frame.append(0x0A)
                _ = frame.withUnsafeBytes { send(fd, $0.baseAddress, frame.count, 0) }
            }
        }
    }
}
