@testable import CmuxNextApp
import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// ``SessionTransferService`` reaches the app only through ``SessionTransferHost``, so a fake host
/// drives it with no AppServices: an absent daemon, its own socket and a chat it cannot host.
@MainActor @Suite
struct SessionTransferHostTests {
    /// `session.transfer.complete` with no daemon connection fails as unavailable.
    @Test func completeWithoutDaemonConnectionIsUnavailable() async {
        let service = SessionTransferService(host: FakeTransferHost(), peerSocketPaths: { [] })
        let failure = await transferFailure { try await service.complete(surfaces: ["7"]) }
        #expect(failure.map(Self.isUnavailable) == true)
    }

    /// Discovery never contacts the host's own control socket, even when the peer list names it.
    @Test func discoveryLeavesTheOwnSocketOut() async throws {
        let peer = try RefusingSocket()
        defer { peer.remove() }

        // Named as another build's socket, it is contacted and refuses (classic's `cmuxOnly` answer).
        let firstRequest = Task.detached { [listener = peer.listener] in serveOneRefusal(listener) }
        let other = SessionTransferService(host: FakeTransferHost(ownSocketPath: "/nonexistent/own.sock"),
                                           peerSocketPaths: { [path = peer.path] in [path] })
        let refused = await transferFailure { try await other.discover(only: peer.path) }
        #expect(refused.map(Self.isPeerRefused) == true)
        #expect(await firstRequest.value.contains("system.identify"))

        // Named as the host's own socket, it is skipped: no refusal, no peers.
        let nextRequest = Task.detached { [listener = peer.listener] in serveOneRefusal(listener) }
        let own = SessionTransferService(host: FakeTransferHost(ownSocketPath: peer.path), peerSocketPaths: { [path = peer.path] in [path] })
        let peers = try await own.discover(only: peer.path)
        #expect(peers.isEmpty)
        // Discovery sent nothing, so the first line the socket reads is this test's own.
        try peer.send(line: "after-discovery")
        #expect(await nextRequest.value == "after-discovery")
    }

    /// A chat the app cannot host is refused before this build's acpmux runs or the source closes.
    @Test func chatMoveWithoutAHostablePaneRunsNoAcpmux() async {
        let host = FakeTransferHost(canHostChats: false)
        let service = SessionTransferService(host: host, peerSocketPaths: { [] })
        var item = SessionTransferItem(sourceSurface: "3", workspace: "w", kind: .chat, title: "Chat", cwd: nil, sshTarget: nil,
                                       command: nil, agentHarness: "claude", agentSessionID: "session-1")
        item.acpmuxSocket = "/nonexistent/acpmux.sock"
        let peer = SessionTransferPeer(path: "/nonexistent/peer.sock", app: "cmux", build: "1", tag: nil, pid: 1, items: [item])

        let failure = await transferFailure { try await service.moveChat(item, from: peer, interrupt: false) }
        #expect(failure.map(Self.isAgentNotOpened) == true)
        #expect(host.acpmuxReads == 0)
        #expect(host.prewarms == 0)
        #expect(host.createdWorkspaces.isEmpty)
    }

    private static func isUnavailable(_ failure: SessionTransferService.Failure) -> Bool {
        if case .unavailable = failure { true } else { false }
    }

    private static func isPeerRefused(_ failure: SessionTransferService.Failure) -> Bool {
        if case .peerRefused = failure { true } else { false }
    }

    private static func isAgentNotOpened(_ failure: SessionTransferService.Failure) -> Bool {
        if case .agentNotOpened = failure { true } else { false }
    }
}

/// The transfer failure `body` throws, nil when it returns or throws something else.
@MainActor
private func transferFailure<T>(_ body: () async throws -> T) async -> SessionTransferService.Failure? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error as? SessionTransferService.Failure
    }
}

/// A host with no app behind it: no daemon connection, an empty store, no acpmux. It counts
/// what the service asks for, so a test sees what a refused move never touched.
@MainActor
private final class FakeTransferHost: SessionTransferHost {
    let ownSocketPath: String?
    let canHostChats: Bool?
    let daemonStore: DaemonStore? = DaemonStore()
    private(set) var acpmuxReads = 0
    private(set) var prewarms = 0
    private(set) var createdWorkspaces: [String] = []

    init(ownSocketPath: String? = nil, canHostChats: Bool? = true) {
        self.ownSocketPath = ownSocketPath
        self.canHostChats = canHostChats
    }

    var daemonConnection: DaemonConnection? { nil }
    var acpmux: SessionTransferAcpmux? {
        acpmuxReads += 1
        return nil
    }

    func createAgentWorkspace(cwd: String?, name: String?, harness: String, sessionID: String) async throws -> String {
        createdWorkspaces.append("agent:\(sessionID)")
        return "agent-workspace"
    }

    func createTerminalWorkspace(cwd: String?, name: String?, command: String?) async throws -> String {
        createdWorkspaces.append("terminal")
        return "terminal-workspace"
    }

    func createChatWorkspace(name: String?, session: String) async throws -> String {
        createdWorkspaces.append("chat:\(session)")
        return "chat-workspace"
    }

    func agentTab(showing session: String) -> String? { nil }
    func localChats() -> [String: (session: String, harness: String?)] { [:] }
    func prewarmLocalChatHost() async throws { prewarms += 1 }
}

/// A listening unix socket this user owns, at a short `/tmp` path (sun_path holds 104 bytes).
private struct RefusingSocket {
    let path = "/tmp/cmux-st-\(UUID().uuidString.prefix(8)).sock"
    let listener: Int32

    init() throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        let bound = withUnixAddress(path) { Darwin.bind(descriptor, $0, $1) }
        guard bound == 0, Darwin.listen(descriptor, 4) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        listener = descriptor
    }

    /// Connects and writes `line`, as a client the socket serves next.
    func send(line: String) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        try #require(withUnixAddress(path) { Darwin.connect(descriptor, $0, $1) } == 0)
        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let bytes = Array((line + "\n").utf8)
        try #require(Darwin.write(descriptor, bytes, bytes.count) == bytes.count)
    }

    func remove() {
        Darwin.close(listener)
        Darwin.unlink(path)
    }
}

/// Accepts one connection on `listener`, reads its first line, answers classic's refusal and
/// closes; returns the line. It blocks until a client connects, so it runs detached.
private nonisolated func serveOneRefusal(_ listener: Int32) -> String {
    let connection = Darwin.accept(listener, nil, nil)
    guard connection >= 0 else { return "" }
    defer { Darwin.close(connection) }
    var noSigPipe: Int32 = 1 // the client may hang up first; the answer then fails with EPIPE, not a signal
    _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var line = [UInt8]()
    var byte: UInt8 = 0
    while Darwin.read(connection, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
    let answer = Array("ERROR: Access denied\n".utf8)
    _ = Darwin.write(connection, answer, answer.count)
    return String(decoding: line, as: UTF8.self)
}

/// Calls `body` with `path` as a `sockaddr_un`.
private nonisolated func withUnixAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}
