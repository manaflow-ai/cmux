// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import os
import Synchronization

private let socketLogger = Logger(subsystem: "com.cmuxterm.cua", category: "socket")

/// The helper's Unix socket. Each connection is checked with
/// `AdmissionPolicy` before the helper reads a byte; a refused peer gets one
/// line `{"ok":false,"error":"refused","reason":...}` and the connection closes.
/// An admitted peer sends `{"secret":"<hex>"}` first, then requests:
///   {"id":N,"method":"tools/list"}
///   {"id":N,"method":"tools/call","name":"click","arguments":{...}}
/// and gets `{"id":N,"ok":true,"result":...}` or `{"id":N,"ok":false,"error":"..."}`.
public final class HelperSocketServer: Sendable {
    public let path: String
    private let admission: AdmissionState
    private let inspector: any PeerInspecting
    private let tools: any ToolInvoking
    private let listener = Mutex<Int32>(-1)

    public init(path: String, admission: AdmissionState, inspector: any PeerInspecting, tools: any ToolInvoking) {
        self.path = path
        self.admission = admission
        self.inspector = inspector
        self.tools = tools
    }

    public enum StartError: Error, Equatable {
        case directoryNotPrivate(String)
        case pathTooLong
        case socket(Int32)
    }

    public func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        guard PrivateDirectory.prepare(directory) else { throw StartError.directoryNotPrivate(directory) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw StartError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StartError.socket(errno) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        unlink(path)
        let previous = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previous)
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 16) == 0 else {
            let failure = errno
            close(descriptor)
            throw StartError.socket(failure)
        }
        listener.withLock { $0 = descriptor }
        let thread = Thread { [self] in acceptLoop(descriptor) }
        thread.name = "cua-helper-accept"
        thread.start()
    }

    public func stop() {
        let descriptor = listener.withLock { value -> Int32 in
            let old = value
            value = -1
            return old
        }
        guard descriptor >= 0 else { return }
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(path)
    }

    private func acceptLoop(_ descriptor: Int32) {
        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let thread = Thread { [self] in serve(client) }
            thread.name = "cua-helper-connection"
            thread.start()
        }
    }

    /// Checks identity at accept, then the secret, then serves requests.
    func serve(_ client: Int32) {
        let connection = Connection(descriptor: client)
        let config = admission.current
        let facts = inspector.facts(forConnection: client, requirement: config?.acpmuxRequirement)
        let identityRefusal: AdmissionRefusal? = if let facts {
            AdmissionPolicy.checkIdentity(facts, config: config)
        } else {
            .invalidSignature
        }
        if let refusal = identityRefusal {
            socketLogger.notice("refused peer pid=\(facts?.stamp.pid ?? -1, privacy: .public) reason=\(refusal.rawValue, privacy: .public)")
            return connection.refuse(refusal)
        }
        guard let config else { return connection.refuse(.notConfigured) }
        var buffer = HelperWire.LineBuffer()
        var admitted = false
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(client, &bytes, bytes.count)
            if count <= 0 { break }
            guard let lines = buffer.append(Data(bytes[0..<count])) else { break }
            for line in lines {
                if !admitted {
                    let secret = (HelperWire.object(line)?["secret"] as? String).flatMap(HelperWire.unhex)
                    if let refusal = AdmissionPolicy.checkSecret(secret, config: config) {
                        socketLogger.notice("refused peer pid=\(facts?.stamp.pid ?? -1, privacy: .public) reason=\(refusal.rawValue, privacy: .public)")
                        return connection.refuse(refusal)
                    }
                    admitted = true
                    connection.write(HelperWire.line(["ok": true, "protocol": HelperWire.protocolVersion]))
                    continue
                }
                handle(line, connection: connection)
            }
        }
        connection.close()
    }

    private func handle(_ line: Data, connection: Connection) {
        guard let request = HelperWire.object(line) else {
            return connection.write(HelperWire.line(["ok": false, "error": "invalid request"]))
        }
        let id = HelperWire.json(request["id"] ?? NSNull())
        let method = request["method"] as? String ?? ""
        let name = request["name"] as? String
        let arguments = HelperWire.json(request["arguments"] ?? [String: Any]())
        let tools = self.tools
        Task.detached {
            do {
                let result: Data
                switch method {
                case "tools/list": result = try await tools.listTools()
                case "tools/call":
                    guard let name, !name.isEmpty else { throw ToolError("tools/call needs a name") }
                    result = try await tools.invoke(name: name, arguments: arguments)
                default: throw ToolError("unknown method \(method)")
                }
                connection.write(HelperWire.line(["ok": true], raw: ["id": id, "result": result]))
            } catch {
                connection.write(HelperWire.line(["ok": false, "error": String(describing: error)],
                                                 raw: ["id": id]))
            }
        }
    }

    /// One client socket; writes are serialized, close happens once.
    final class Connection: Sendable {
        private let state: Mutex<Int32>

        init(descriptor: Int32) { state = Mutex(descriptor) }

        func write(_ data: Data) {
            state.withLock { descriptor in
                guard descriptor >= 0 else { return }
                data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                        if written <= 0 { if errno == EINTR { continue }; return }
                        offset += written
                    }
                }
            }
        }

        func refuse(_ refusal: AdmissionRefusal) {
            write(HelperWire.line(["ok": false, "error": "refused", "reason": refusal.rawValue]))
            close()
        }

        func close() {
            state.withLock { descriptor in
                guard descriptor >= 0 else { return }
                Darwin.close(descriptor)
                descriptor = -1
            }
        }
    }
}
