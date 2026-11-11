#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import Darwin
package import Foundation

/// The fixture of the `permission-feed-peer` capture scenes (CaptureSceneRegistry+Home.swift):
/// Chief Home's pinned Needs you showing an agent permission prompt that the app's real feed
/// bridge (`AcpmuxPermissionFeedBridge`) found, then withdrawing it once it is answered elsewhere.
///
/// - An acpmux on a unix socket in this app's process, so the bridge's server-peer check accepts
///   it (the peer is this app). It serves one peer session (`acp_peer_capture` of `peer-a`,
///   listed by its qualified id `peer-a/acp_peer_capture`) holding one prompt: `initialize`, the
///   watch and `_acpmux/sessions` list it; `_acpmux/info` returns the prompt until ``resolve()``
///   and nothing after. Any other request gets an empty result. Only the first connection is served.
/// - The feed owner the bridge calls (``owner(_:)``), as the local daemon's feed: `feed.post`
///   becomes the daemon's `feed.post {item}` (its integration owner), `feed.cancel` its
///   `feed.withdraw {dedupe_key}`, both through `send`.
package nonisolated final class HomeNeedsYouCapture: @unchecked Sendable { // crash-allow: every mutable field is in `state` (a Mutex)
    package static let rawSession = "acp_peer_capture"
    package static let qualifiedSession = "peer-a/acp_peer_capture"
    package static let permission = "perm-capture"
    /// The dedupe key the stub posts under: the next scene withdraws a former scene's item by it.
    package static let feedKey = "capture:acpmux:perm-capture"

    /// `feed.withdraw`'s params for the stub's item.
    package static let withdrawParams = Data(#"{"dedupe_key":"capture:acpmux:perm-capture"}"#.utf8)

    /// The peer's ids as its notices carry them: the raw id, the peer and the row's qualified id.
    static var peerIds: [String: Any] { ["sessionId": rawSession, "peer": "peer-a", "qualifiedSessionId": qualifiedSession] }

    /// The prompt the peer session holds.
    static var request: [String: Any] {
        ["sessionId": rawSession,
         "toolCall": ["toolCallId": "call-1", "title": "Run make test", "kind": "execute", "rawInput": ["command": "make test"]],
         "options": [["optionId": "allow", "kind": "allow_once", "name": "Allow"],
                     ["optionId": "reject", "kind": "reject_once", "name": "Deny"]]]
    }

    private struct State {
        var client: Int32 = -1
        var clientSource: (any DispatchSourceRead)?
        var buffer = Data()
        var resolved = false
        var infoReads: [String] = []
        var posted: [String: String] = [:]
    }

    package let socket: String
    private let listener: Int32
    private let listenerSource: any DispatchSourceRead
    private let state = Mutex(State())
    /// One feed op on the app's local daemon: its name and its params as a JSON object.
    private let send: @Sendable (String, Data) -> Void

    /// The session ids of the `_acpmux/info` reads that reached it, in order.
    package var infoReads: [String] { state.withLock { $0.infoReads } }
    /// Whether the bridge connected.
    package var connected: Bool { state.withLock { $0.client >= 0 } }

    /// Listens on a new socket under /tmp (a unix socket path must stay short).
    package init(send: @escaping @Sendable (String, Data) -> Void) throws {
        self.send = send
        socket = "/tmp/cmux-cap-\(UUID().uuidString.prefix(8)).sock"
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socket.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in path.withUnsafeBytes { buffer.copyMemory(from: $0) } }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        listener = fd
        listenerSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        listenerSource.setEventHandler { [weak self] in self?.accepted() }
        listenerSource.setCancelHandler { close(fd) }
        listenerSource.resume()
    }

    deinit { stop() }

    /// Closes the connection and the socket.
    package func stop() {
        let source = state.withLock { state -> (any DispatchSourceRead)? in
            defer { (state.client, state.clientSource) = (-1, nil) }
            return state.clientSource
        }
        source?.cancel()
        if !listenerSource.isCancelled {
            listenerSource.cancel()
            unlink(socket)
        }
    }

    /// The live `_acpmux/permission_pending` for the prompt, as acpmux sends a watcher.
    package func notifyPending() {
        notify("_acpmux/permission_pending", Self.peerIds.merging(
            ["permissionId": Self.permission, "request": Self.request, "seq": 10, "via": "peer"]) { $1 })
    }

    /// Answered on the peer: `_acpmux/info` lists nothing from now on, and the watchers get
    /// `_acpmux/session_changed` (`permission_resolved`) with the peer's ids.
    package func resolve() {
        state.withLock { $0.resolved = true }
        notify("_acpmux/session_changed", Self.peerIds.merging(
            ["kind": "permission_resolved", "recordKind": "permission_auto", "seq": 11, "session": Self.peerIds]) { $1 })
    }

    /// The bridge's feed owner (`v1/ops`).
    package func owner(_ body: [String: Any]) -> [String: Any] {
        let params = body["params"] as? [String: Any] ?? [:]
        switch body["op"] as? String {
        case "feed.post":
            let id = "fi_capture_" + UUID().uuidString.prefix(8).lowercased()
            let now = Date().timeIntervalSince1970 * 1000
            let item = params.merging(["id": id, "dedupe_key": Self.feedKey, "home": "local:capture", "state": "open",
                                       "count": 1, "revision": 1, "created_at": now, "updated_at": now]) { $1 }
            state.withLock { $0.posted[id] = Self.feedKey }
            guard let data = try? JSONSerialization.data(withJSONObject: ["item": item]) else { return [:] }
            send("feed.post", data)
            return ["value": ["item": ["id": id]]]
        case "feed.cancel":
            if let item = params["item"] as? String, state.withLock({ $0.posted.removeValue(forKey: item) }) != nil {
                send("feed.withdraw", Self.withdrawParams)
            }
            return ["value": [String: Any]()]
        default:
            return [:]
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        reply(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func reply(_ message: [String: Any]) {
        guard var frame = try? JSONSerialization.data(withJSONObject: message) else { return }
        frame.append(0x0A)
        state.withLock { state in
            guard state.client >= 0 else { return }
            _ = frame.withUnsafeBytes { Darwin.send(state.client, $0.baseAddress, frame.count, 0) }
        }
    }

    private func accepted() {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        let first = state.withLock { state -> Bool in
            guard state.client < 0, state.clientSource == nil else { return false }
            (state.client, state.clientSource) = (fd, source)
            return true
        }
        guard first else {
            close(fd)
            return
        }
        source.setEventHandler { [weak self] in self?.readable(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    private func readable(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = recv(fd, &chunk, chunk.count, 0)
        guard count > 0 else {
            let source = state.withLock { state -> (any DispatchSourceRead)? in
                defer { (state.client, state.clientSource) = (-1, nil) }
                return state.clientSource
            }
            source?.cancel()
            return
        }
        let lines = state.withLock { state -> [Data] in
            state.buffer.append(contentsOf: chunk[0..<count])
            var lines: [Data] = []
            while let newline = state.buffer.firstIndex(of: 0x0A) {
                lines.append(Data(state.buffer[state.buffer.startIndex..<newline]))
                state.buffer.removeSubrange(state.buffer.startIndex...newline)
            }
            return lines
        }
        for line in lines {
            guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = request["id"], let method = request["method"] as? String else { continue }
            answer(id: id, method: method, params: request["params"] as? [String: Any] ?? [:])
        }
    }

    private func answer(id: Any, method: String, params: [String: Any]) {
        let row = Self.peerIds.merging(["pendingPermissions": 1]) { $1 }
        let result: [String: Any]
        switch method {
        case "initialize":
            // `session-list-pending-v1` is AcpmuxSessionListGate.pendingCapability.
            result = ["_meta": ["acpmux": ["capabilities": ["acpmux-v1", "session-list-pending-v1"]]]]
        case "_acpmux/watch", "_acpmux/sessions":
            result = ["sessions": [row]]
        case "_acpmux/info":
            let resolved = state.withLock { state -> Bool in
                state.infoReads.append(params["sessionId"] as? String ?? "")
                return state.resolved
            }
            result = ["pending": resolved ? [] : [["permissionId": Self.permission, "request": Self.request]]]
        default:
            result = [:]
        }
        reply(["jsonrpc": "2.0", "id": id, "result": result])
    }
}
#endif
