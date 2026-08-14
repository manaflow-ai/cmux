import Darwin
import Foundation
import Network
import Testing
@testable import CmuxRemoteWorkspace

/// Pass-through rewriter for policy tests: the policy gate lives inside the
/// relay server, so a trivial conformer is enough to exercise it end to end.
private struct PolicyPassthroughRewriter: RemoteRelayCommandRewriting {
    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        commandLine
    }
}

/// Multi-connection stand-in for the local cmux control socket: accepts any
/// number of connections, records every request, answers each with a fixed
/// `{"ok":true,"result":{}}` line. The relay must forward authorized commands
/// here and must never connect for denied ones.
private final class PolicyFakeUnixSocketServer: @unchecked Sendable {
    let path: String
    private let responseBody: Data
    private let lock = NSLock()
    private var _requests: [Data] = []
    private let listenFD: Int32
    private var shouldStop = false

    var requests: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    init(responseBody: Data = Data("{\"ok\":true,\"result\":{}}\n".utf8)) throws {
        self.responseBody = responseBody
        path = NSTemporaryDirectory() + "cmux-relay-policy-test-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "PolicyFakeUnixSocketServer", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "socket() failed errno=\(errno)"])
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        precondition(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        withUnsafeMutableBytes(of: &address) { raw in
            pathBytes.withUnsafeBytes { src in
                raw.baseAddress!.advanced(by: offset).copyMemory(from: src.baseAddress!, byteCount: pathBytes.count)
            }
        }
        let len = socklen_t(MemoryLayout.size(ofValue: address.sun_family) + pathBytes.count)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        guard bound == 0 else {
            let bindErrno = errno
            Darwin.close(fd)
            throw NSError(domain: "PolicyFakeUnixSocketServer", code: Int(bindErrno), userInfo: [NSLocalizedDescriptionKey: "bind() failed errno=\(bindErrno)"])
        }
        guard listen(fd, 8) == 0 else {
            let listenErrno = errno
            Darwin.close(fd)
            throw NSError(domain: "PolicyFakeUnixSocketServer", code: Int(listenErrno), userInfo: [NSLocalizedDescriptionKey: "listen() failed errno=\(listenErrno)"])
        }
        listenFD = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                guard let self else {
                    Darwin.close(client)
                    return
                }
                self.lock.lock()
                let stopped = self.shouldStop
                self.lock.unlock()
                if stopped {
                    Darwin.close(client)
                    return
                }
                self.serve(client: client)
            }
        }
    }

    private func serve(client: Int32) {
        var request = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(client, &scratch, scratch.count)
            if count > 0 {
                request.append(scratch, count: count)
                continue
            }
            break
        }
        lock.lock()
        _requests.append(request)
        lock.unlock()
        responseBody.withUnsafeBytes { raw in
            _ = Darwin.write(client, raw.baseAddress, raw.count)
        }
        Darwin.close(client)
    }

    func close() {
        lock.lock()
        shouldStop = true
        lock.unlock()
        Darwin.close(listenFD)
        unlink(path)
    }
}

/// One-shot relay client: performs the documented HMAC challenge-response,
/// sends exactly one command line, then collects the response until close.
private struct PolicyRelayExchange {
    let responseLines: [[String: Any]]
    let rawResponse: String
    let closedByPeer: Bool
}

private func runPolicyRelayExchange(
    port: Int,
    relayID: String,
    tokenHex: String,
    commandLine: String
) throws -> PolicyRelayExchange {
    let queue = DispatchQueue(label: "relay-policy-test-client")
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var received = Data()
        var closed = false
    }
    let state = State()
    let connection = NWConnection(
        host: "127.0.0.1",
        port: NWEndpoint.Port(rawValue: UInt16(port))!,
        using: .tcp
    )
    connection.start(queue: queue)
    func receiveLoop(_ connection: NWConnection, _ state: State) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            state.lock.lock()
            if let data { state.received.append(data) }
            if isComplete || error != nil { state.closed = true }
            let done = state.closed
            state.lock.unlock()
            if !done { receiveLoop(connection, state) }
        }
    }
    receiveLoop(connection, state)

    func wait(_ timeout: TimeInterval = 5.0, _ predicate: (Data, Bool) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            state.lock.lock()
            let snapshot = state.received
            let isClosed = state.closed
            state.lock.unlock()
            if predicate(snapshot, isClosed) { return true }
            usleep(20_000)
        }
        return false
    }
    func send(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    defer { connection.cancel() }

    // Challenge.
    guard wait(5.0, { data, _ in data.contains(0x0A) }) else {
        Issue.record("timed out waiting for relay challenge")
        return PolicyRelayExchange(responseLines: [], rawResponse: "", closedByPeer: false)
    }
    state.lock.lock()
    let challengeLine = state.received.split(separator: 0x0A).first.map { Data($0) } ?? Data()
    state.received.removeAll(keepingCapacity: true)
    state.lock.unlock()
    let challenge = try JSONSerialization.jsonObject(with: challengeLine) as? [String: Any]
    let nonce = try #require(challenge?["nonce"] as? String)

    // Auth.
    let token = try #require(RemoteCLIRelayServer.Session.hexData(from: tokenHex))
    let message = Data("relay_id=\(relayID)\nnonce=\(nonce)\nversion=1".utf8)
    let mac = RemoteCLIRelayServer.Session.authMAC(token: token, message: message)
    let auth: [String: Any] = [
        "relay_id": relayID,
        "mac": mac.map { String(format: "%02x", $0) }.joined(),
    ]
    send(connection, try JSONSerialization.data(withJSONObject: auth) + Data([0x0A]))
    guard wait(5.0, { data, _ in data.contains(0x0A) }) else {
        Issue.record("timed out waiting for relay auth response")
        return PolicyRelayExchange(responseLines: [], rawResponse: "", closedByPeer: false)
    }
    state.lock.lock()
    let authLine = state.received.split(separator: 0x0A).first.map { Data($0) } ?? Data()
    state.received.removeAll(keepingCapacity: true)
    state.lock.unlock()
    let authResponse = try JSONSerialization.jsonObject(with: authLine) as? [String: Any]
    guard (authResponse?["ok"] as? Bool) == true else {
        Issue.record("relay authentication failed: \(String(decoding: authLine, as: UTF8.self))")
        return PolicyRelayExchange(responseLines: [], rawResponse: "", closedByPeer: false)
    }

    // Command; the relay answers then closes the connection.
    send(connection, Data(commandLine.utf8) + Data([0x0A]))
    _ = wait(5.0) { data, closed in closed }

    state.lock.lock()
    let raw = state.received
    let wasClosed = state.closed
    state.lock.unlock()
    let lines = raw.split(separator: 0x0A).compactMap {
        try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
    }
    return PolicyRelayExchange(
        responseLines: lines,
        rawResponse: String(decoding: raw, as: UTF8.self),
        closedByPeer: wasClosed
    )
}

@Suite("RemoteCLIRelayPolicy", .serialized)
struct RemoteCLIRelayPolicyTests {
    private let tokenHex = "00112233445566778899aabbccddeeff"
    private let relayID = "relay-policy"

    private func withServer(
        workspaceAliases: [UUID: UUID] = [:],
        surfaceAliases: [UUID: UUID] = [:],
        responseBody: Data = Data("{\"ok\":true,\"result\":{}}\n".utf8),
        _ body: (Int, PolicyFakeUnixSocketServer) throws -> Void
    ) throws {
        let unixServer = try PolicyFakeUnixSocketServer(responseBody: responseBody)
        defer { unixServer.close() }
        let server = try RemoteCLIRelayServer(
            localSocketPath: unixServer.path,
            relayID: relayID,
            relayTokenHex: tokenHex,
            commandRewriter: PolicyPassthroughRewriter()
        )
        defer { server.stop() }
        server.updateRemoteRelayIDAliases(
            workspaceAliases: workspaceAliases,
            surfaceAliases: surfaceAliases
        )
        // The alias update and every later connection acceptance are enqueued
        // on the relay's single serial queue in FIFO order, so the aliases are
        // guaranteed visible to any command rewrite that follows.
        let port = try server.start()
        try body(port, unixServer)
    }

    private func expectDenial(
        _ exchange: PolicyRelayExchange,
        _ unixServer: PolicyFakeUnixSocketServer,
        _ label: String
    ) {
        let response = exchange.responseLines.first
        #expect(response?["ok"] as? Bool == false, "\(label): expected ok:false denial, got \(exchange.rawResponse)")
        #expect(
            (response?["error"] as? [String: Any])?["code"] as? String == "remote_relay_denied",
            "\(label): expected remote_relay_denied error code, got \(exchange.rawResponse)"
        )
        #expect(unixServer.requests.isEmpty, "\(label): denied command must not reach the local socket")
    }

    @Test("workspace.create with initial_command is denied (GHSA-9vmv-3hjw-j28c)")
    func deniesWorkspaceCreateInitialCommand() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: #"{"id":"p1","method":"workspace.create","params":{"initial_command":"touch /tmp/pwned"}}"#
            )
            expectDenial(exchange, unixServer, "workspace.create initial_command")
        }
    }

    @Test("workspace.create is denied even without command params")
    func deniesWorkspaceCreate() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: #"{"id":"p2","method":"workspace.create","params":{"title":"x"}}"#
            )
            expectDenial(exchange, unixServer, "workspace.create")
        }
    }

    @Test("surface.send_text to an unmapped local surface is denied")
    func deniesUnmappedSurfaceSendText() throws {
        let alias = (remote: UUID(), local: UUID())
        try withServer(surfaceAliases: [alias.remote: alias.local]) { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p3","method":"surface.send_text","params":{"surface_id":"\(UUID().uuidString)","text":"open https://example.com\\n"}}
                """
            )
            expectDenial(exchange, unixServer, "unmapped send_text")
        }
    }

    @Test("surface.send_text to an aliased remote surface is forwarded")
    func allowsAliasedSurfaceSendText() throws {
        let alias = (remote: UUID(), local: UUID())
        try withServer(surfaceAliases: [alias.remote: alias.local]) { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p4","method":"surface.send_text","params":{"surface_id":"\(alias.remote.uuidString)","text":"ls\\n"}}
                """
            )
            #expect(exchange.responseLines.first?["ok"] as? Bool == true)
            #expect(unixServer.requests.count == 1)
        }
    }

    @Test("methods outside the relay allowlist are denied")
    func deniesNonAllowlistedMethod() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: #"{"id":"p5","method":"system.exec","params":{"command":"id"}}"#
            )
            expectDenial(exchange, unixServer, "non-allowlisted method")
        }
    }

    @Test("non-JSON command lines are denied")
    func deniesNonJSONCommandLine() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: "workspace.list {}"
            )
            expectDenial(exchange, unixServer, "non-JSON line")
        }
    }

    @Test("surface.respawn is denied even on an owned surface (local respawn fallback)")
    func deniesRespawnOnAliasedSurface() throws {
        // The app respawns a plain SSH remote surface locally under the same
        // surface ID, so relay-carried respawn would convert an owned surface
        // into a local shell the remote can drive. Deny the method outright.
        let alias = (remote: UUID(), local: UUID())
        try withServer(surfaceAliases: [alias.remote: alias.local]) { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p6","method":"surface.respawn","params":{"surface_id":"\(alias.remote.uuidString)"}}
                """
            )
            expectDenial(exchange, unixServer, "respawn on owned surface")
        }
    }

    @Test("surface.respawn with a start command on an unmapped surface is denied")
    func deniesRespawnOnUnmappedSurface() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p7","method":"surface.respawn","params":{"surface_id":"\(UUID().uuidString)","tmux_start_command":"/bin/sh -c id"}}
                """
            )
            expectDenial(exchange, unixServer, "unmapped respawn")
        }
    }

    @Test("surface.create without a remote target is denied")
    func deniesSurfaceCreateWithoutTarget() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: #"{"id":"p8","method":"surface.create","params":{"type":"terminal"}}"#
            )
            expectDenial(exchange, unixServer, "surface.create without target")
        }
    }

    @Test("surface.create on an aliased remote workspace is forwarded")
    func allowsSurfaceCreateOnAliasedWorkspace() throws {
        let alias = (remote: UUID(), local: UUID())
        try withServer(workspaceAliases: [alias.remote: alias.local]) { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p9","method":"surface.create","params":{"type":"terminal","workspace_id":"\(alias.remote.uuidString)"}}
                """
            )
            #expect(exchange.responseLines.first?["ok"] as? Bool == true)
            #expect(unixServer.requests.count == 1)
        }
    }

    @Test("workspace.group.delete is denied")
    func deniesWorkspaceGroupDelete() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p10","method":"workspace.group.delete","params":{"group_id":"\(UUID().uuidString)","close_workspaces":true}}
                """
            )
            expectDenial(exchange, unixServer, "workspace.group.delete")
        }
    }

    @Test("window.create is denied")
    func deniesWindowCreate() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: #"{"id":"p11","method":"window.create","params":{}}"#
            )
            expectDenial(exchange, unixServer, "window.create")
        }
    }

    @Test("send_text to a live local ID from the alias values is forwarded (fresh-session shape)")
    func allowsAliasedLocalIDValueSendText() throws {
        // Fresh remote sessions carry no distinct remote IDs: the remote
        // shell's environment holds the workspace's live local UUIDs, and the
        // app syncs them as identity alias entries.
        let localSurface = UUID()
        try withServer(surfaceAliases: [localSurface: localSurface]) { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p12","method":"surface.send_text","params":{"surface_id":"\(localSurface.uuidString)","text":"ls\\n"}}
                """
            )
            #expect(exchange.responseLines.first?["ok"] as? Bool == true)
            #expect(unixServer.requests.count == 1)
        }
    }

    @Test("lifecycle methods from remote bootstrap scripts are forwarded")
    func allowsLifecycleTerminalSessionLaunching() throws {
        let localWorkspace = UUID()
        try withServer(workspaceAliases: [localWorkspace: localWorkspace]) { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p13","method":"workspace.remote.terminal_session_launching","params":{"workspace_id":"\(localWorkspace.uuidString)","terminal_lifecycle_id":"lc","attempt_id":"a1"}}
                """
            )
            #expect(exchange.responseLines.first?["ok"] as? Bool == true)
            #expect(unixServer.requests.count == 1)
        }
    }

    @Test("a surface created through the relay is immediately drivable by its returned ID")
    func createdSurfaceIsImmediatelyUsable() throws {
        // The remote learns a created surface's local ID from the create
        // response, so the relay records response IDs at response time;
        // alias-map pushes from the app are too racy for split-then-send.
        let workspaceAlias = (remote: UUID(), local: UUID())
        let createdSurface = UUID()
        let createResponse = Data("""
        {"ok":true,"result":{"surface_id":"\(createdSurface.uuidString)","workspace_id":"\(workspaceAlias.local.uuidString)"}}

        """.utf8)
        try withServer(
            workspaceAliases: [workspaceAlias.remote: workspaceAlias.local],
            responseBody: createResponse
        ) { port, unixServer in
            let split = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"c1","method":"surface.split","params":{"workspace_id":"\(workspaceAlias.remote.uuidString)","direction":"right"}}
                """
            )
            #expect(split.responseLines.first?["ok"] as? Bool == true)

            let send = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"c2","method":"surface.send_text","params":{"surface_id":"\(createdSurface.uuidString)","text":"ls\\n"}}
                """
            )
            #expect(
                send.responseLines.first?["ok"] as? Bool == true,
                "the created surface must be drivable immediately: \(send.rawResponse)"
            )
            #expect(unixServer.requests.count == 2)
        }
    }
}
