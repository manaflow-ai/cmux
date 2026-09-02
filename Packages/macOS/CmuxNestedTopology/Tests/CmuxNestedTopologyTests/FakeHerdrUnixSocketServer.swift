#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
@testable import CmuxNestedTopology

/// Scriptable newline-delimited JSON Unix socket server for Herdr adapter tests.
final class FakeHerdrUnixSocketServer: @unchecked Sendable {
    typealias Handler = (_ requestLine: String, _ requestID: String, _ method: String) -> [Data]

    let path: String
    private let listenFD: Int32
    private let lock = NSLock()
    private var handler: Handler
    private var acceptThread: Thread?
    private var running = true
    private var writeFragmentSize: Int?
    private var writeDelay: Duration?
    private var closeAfterAccept = false
    private var stallResponses = false

    init(handler: @escaping Handler) throws {
        self.handler = handler
        path = NSTemporaryDirectory() + "herdr-fake-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)

        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else {
            throw NSError(
                domain: "FakeHerdrUnixSocketServer",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "socket() failed"]
            )
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        precondition(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        withUnsafeMutableBytes(of: &address) { raw in
            pathBytes.withUnsafeBytes { src in
                raw.baseAddress!.advanced(by: offset)
                    .copyMemory(from: src.baseAddress!, byteCount: pathBytes.count)
            }
        }
        let len = socklen_t(MemoryLayout.size(ofValue: address.sun_family) + pathBytes.count)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len)
            }
        }
        guard bound == 0 else {
            let bindErrno = errno
            _ = posixClose(fd)
            throw NSError(
                domain: "FakeHerdrUnixSocketServer",
                code: Int(bindErrno),
                userInfo: [NSLocalizedDescriptionKey: "bind() failed errno=\(bindErrno)"]
            )
        }
        guard listen(fd, 16) == 0 else {
            let listenErrno = errno
            _ = posixClose(fd)
            throw NSError(
                domain: "FakeHerdrUnixSocketServer",
                code: Int(listenErrno),
                userInfo: [NSLocalizedDescriptionKey: "listen() failed errno=\(listenErrno)"]
            )
        }
        listenFD = fd
        startAcceptLoop()
    }

    func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func setWriteFragmentSize(_ size: Int?) {
        lock.lock()
        writeFragmentSize = size
        lock.unlock()
    }

    func setWriteDelay(_ delay: Duration?) {
        lock.lock()
        writeDelay = delay
        lock.unlock()
    }

    func setCloseAfterAccept(_ value: Bool) {
        lock.lock()
        closeAfterAccept = value
        lock.unlock()
    }

    func setStallResponses(_ value: Bool) {
        lock.lock()
        stallResponses = value
        lock.unlock()
    }

    func shutdown() {
        lock.lock()
        running = false
        lock.unlock()
        // Unblock a thread parked in accept() before invalidating the descriptor.
        #if canImport(Darwin)
        _ = Darwin.shutdown(listenFD, SHUT_RDWR)
        #else
        _ = Glibc.shutdown(listenFD, Int32(SHUT_RDWR))
        #endif
        _ = posixClose(listenFD)
        unlink(path)
    }

    private func startAcceptLoop() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            while true {
                self.lock.lock()
                let stillRunning = self.running
                self.lock.unlock()
                guard stillRunning else { return }

                let client = accept(self.listenFD, nil, nil)
                if client < 0 {
                    continue
                }
                Thread.detachNewThread { [weak self] in
                    self?.handleClient(client)
                }
            }
        }
        thread.start()
        acceptThread = thread
    }

    private func handleClient(_ client: Int32) {
        lock.lock()
        let shouldClose = closeAfterAccept
        let stall = stallResponses
        let fragment = writeFragmentSize
        let delay = writeDelay
        let currentHandler = handler
        lock.unlock()

        if shouldClose {
            _ = posixClose(client)
            return
        }

        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(client, &scratch, scratch.count, 0)
            if count <= 0 { break }
            buffer.append(contentsOf: scratch.prefix(count))
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex..<buffer.index(after: newline))
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                let parsed = Self.parseRequest(line)
                if stall {
                    // Leave the client waiting until its timeout fires.
                    Thread.sleep(forTimeInterval: 30)
                    _ = posixClose(client)
                    return
                }
                let chunks = currentHandler(line, parsed.id, parsed.method)
                var closeSubscribeAfterWrite = false
                for chunk in chunks {
                    // Empty chunk is a test sentinel meaning "close after writing prior chunks".
                    if chunk.isEmpty {
                        closeSubscribeAfterWrite = true
                        continue
                    }
                    if let delay {
                        let seconds = Double(delay.components.seconds)
                            + Double(delay.components.attoseconds) / 1e18
                        if seconds > 0 {
                            Thread.sleep(forTimeInterval: seconds)
                        }
                    }
                    if let fragment, fragment > 0 {
                        var offset = 0
                        while offset < chunk.count {
                            let end = min(offset + fragment, chunk.count)
                            let slice = chunk.subdata(in: offset..<end)
                            slice.withUnsafeBytes { raw in
                                _ = posixSend(client, raw.baseAddress, raw.count)
                            }
                            offset = end
                        }
                    } else {
                        chunk.withUnsafeBytes { raw in
                            _ = posixSend(client, raw.baseAddress, raw.count)
                        }
                    }
                }
                // Request/response methods close after one exchange.
                // Subscribe stays open unless the handler requests EOF via an empty chunk.
                if parsed.method != "events.subscribe" || closeSubscribeAfterWrite {
                    _ = posixClose(client)
                    return
                }
            }
        }
        _ = posixClose(client)
    }

    private static func parseRequest(_ line: String) -> (id: String, method: String) {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ("", "")
        }
        let id = object["id"] as? String ?? ""
        let method = object["method"] as? String ?? ""
        return (id, method)
    }
}

private func posixClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}

private func posixSend(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
    // Avoid SIGPIPE when the client cancels/closes mid-write.
    var value: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    return send(fd, buffer, count, 0)
    #else
    return send(fd, buffer, count, Int32(MSG_NOSIGNAL))
    #endif
}

enum HerdrFakeFixtures {
    static let attachmentID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    static let hostSurfaceID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    static func pongJSON(
        id: String,
        protocolNumber: Int = 17,
        version: String = "0.7.0",
        instanceID: String? = nil
    ) -> String {
        let caps = #"{"live_handoff":true,"detached_server_daemon":false}"#
        var instanceField = ""
        if let instanceID {
            instanceField = #","instance_id":"\#(instanceID)""#
        }
        return """
        {"id":"\(id)","result":{"type":"pong","version":"\(version)","protocol":\(protocolNumber),"capabilities":\(caps)\(instanceField)}}
        """
    }

    static func snapshotJSON(id: String, protocolNumber: Int = 17) -> String {
        """
        {"id":"\(id)","result":{"type":"session_snapshot","snapshot":{"version":"0.7.0","protocol":\(protocolNumber),"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","number":1,"label":"Main","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"w1:t1","agent_status":"working","extra_unknown":true}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"Build","focused":true,"pane_count":1,"agent_status":"working"}],"panes":[{"pane_id":"w1:p1","terminal_id":"term1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"label":"agent","agent":"claude","agent_status":"working","revision":1}],"layouts":[],"agents":[{"terminal_id":"term1","agent":"claude","display_agent":"Claude","agent_status":"working","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":true,"revision":1}]}}}
        """
    }

    static func subscriptionStartedJSON(id: String) -> String {
        #"{"id":"\#(id)","result":{"type":"subscription_started"}}"#
    }

    static func errorJSON(id: String, code: String = "not_found", message: String = "missing") -> String {
        #"{"id":"\#(id)","error":{"code":"\#(code)","message":"\#(message)"}}"#
    }

    static func focusOKJSON(id: String, type: String = "ok") -> String {
        #"{"id":"\#(id)","result":{"type":"\#(type)"}}"#
    }

    static func workspaceCreatedEventJSON() -> String {
        #"{"event":"workspace_created","data":{"type":"workspace_created","workspace":{"workspace_id":"w2","number":2,"label":"New","focused":false,"pane_count":0,"tab_count":0,"active_tab_id":"","agent_status":"unknown"}}}"#
    }

    static func paneAgentStatusEventJSON() -> String {
        #"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"blocked","agent":"claude"}}"#
    }

    static func line(_ json: String) -> Data {
        Data((json + "\n").utf8)
    }
}
