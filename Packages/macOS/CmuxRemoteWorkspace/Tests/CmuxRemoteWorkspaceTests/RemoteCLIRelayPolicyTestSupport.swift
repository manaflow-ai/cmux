import Darwin
import Foundation
import Network
import Testing
@testable import CmuxRemoteWorkspace

/// Pass-through rewriter for policy tests: the policy gate lives inside the
/// relay server, so a trivial conformer is enough to exercise it end to end.
struct PolicyPassthroughRewriter: RemoteRelayCommandRewriting {
    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        guard let line = String(data: commandLine, encoding: .utf8),
              let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              var request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return commandLine
        }
        var params = request["params"] as? [String: Any] ?? [:]
        params["_cmux_remote_workspace_id"] = UUID().uuidString
        params["_cmux_remote_relay_request_authentication_code"] = "test"
        request["params"] = params
        guard let rewritten = try? JSONSerialization.data(withJSONObject: request) else {
            return commandLine
        }
        return rewritten + Data([0x0A])
    }
}

/// Multi-connection stand-in for the local cmux control socket: accepts any
/// number of connections, records every request, answers each with a fixed
/// `{"ok":true,"result":{}}` line. The relay must forward authorized commands
/// here and must never connect for denied ones.
final class PolicyFakeUnixSocketServer: @unchecked Sendable {
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
struct PolicyRelayExchange {
    let responseLines: [[String: Any]]
    let rawResponse: String
    let closedByPeer: Bool
}

func runPolicyRelayExchange(
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
    @Sendable func receiveLoop(_ connection: NWConnection, _ state: State) {
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
