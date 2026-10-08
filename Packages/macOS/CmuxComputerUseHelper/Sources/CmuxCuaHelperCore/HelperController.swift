// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import os
import Synchronization

private let controlLogger = Logger(subsystem: "com.cmuxterm.cua", category: "control")

/// The host control pipe: the helper's stdin (host -> helper) and stdout
/// (helper -> host), JSON lines. stdin EOF means the host quit, crashed or
/// stopped the helper: the helper removes its socket and exits. The pipe is
/// not reachable by any other process, so the secret travels here.
///
/// host -> helper:
///   {"type":"configure","socket":PATH,"secret":HEX,"acpmux_cdhashes":[HEX],"acpmux_requirement":STRING|null}
///   {"type":"register_acpmux","pid":N,"start_sec":N,"start_usec":N}
///   {"type":"call","id":N,"name":TOOL,"arguments":{...}}
/// helper -> host:
///   {"type":"ready","protocol":1,"pid":N,"socket":PATH}
///   {"type":"ack","of":"register_acpmux","ok":BOOL}
///   {"type":"result","id":N,"ok":BOOL,"result":...|"error":STRING}
///   {"type":"error","error":STRING}
public final class HelperController: Sendable {
    private let input: Int32
    private let output: Int32
    private let tools: any ToolInvoking
    private let inspector: any PeerInspecting
    private let onExit: @Sendable (Int32) -> Void
    public let admission = AdmissionState()
    private let server = Mutex<HelperSocketServer?>(nil)
    private let writeLock = Mutex(())

    public init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO, tools: any ToolInvoking,
                inspector: any PeerInspecting = KernelPeerInspector(),
                onExit: @escaping @Sendable (Int32) -> Void = { exit($0) }) {
        self.input = input
        self.output = output
        self.tools = tools
        self.inspector = inspector
        self.onExit = onExit
    }

    /// Reads the control pipe on its own thread until EOF.
    public func start() {
        let thread = Thread { [self] in run() }
        thread.name = "cua-helper-control"
        thread.start()
    }

    /// Blocking read loop (the thread body; tests call it directly).
    public func run() {
        var buffer = HelperWire.LineBuffer()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(input, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            guard let lines = buffer.append(Data(bytes[0..<count])) else { break }
            for line in lines { handle(line) }
        }
        // RED STUB (commit 1): EOF is ignored.
        while true { sleep(3600) }
    }

    public func shutdown() {
        let current = server.withLock { value -> HelperSocketServer? in
            let old = value
            value = nil
            return old
        }
        current?.stop()
    }

    private func handle(_ line: Data) {
        guard let message = HelperWire.object(line), let type = message["type"] as? String else {
            return send(["type": "error", "error": "invalid control message"])
        }
        switch type {
        case "configure": configure(message)
        case "register_acpmux":
            var ok = false
            if let pid = message["pid"] as? Int, pid > 1, pid <= Int(Int32.max),
               let seconds = message["start_sec"] as? Int, seconds >= 0,
               let micros = message["start_usec"] as? Int, micros >= 0 {
                ok = admission.register(daemon: ProcessStamp(pid: pid_t(pid), startSeconds: UInt64(seconds),
                                                             startMicroseconds: UInt64(micros)))
            }
            send(["type": "ack", "of": "register_acpmux", "ok": ok])
        case "call":
            let id = HelperWire.json(message["id"] ?? NSNull())
            let name = message["name"] as? String ?? ""
            let arguments = HelperWire.json(message["arguments"] ?? [String: Any]())
            let tools = self.tools
            Task.detached { [self] in
                do {
                    let result = try await tools.invoke(name: name, arguments: arguments)
                    write(HelperWire.line(["type": "result", "ok": true], raw: ["id": id, "result": result]))
                } catch {
                    write(HelperWire.line(["type": "result", "ok": false, "error": String(describing: error)],
                                          raw: ["id": id]))
                }
            }
        default: send(["type": "error", "error": "unknown control message \(type)"])
        }
    }

    private func configure(_ message: [String: Any]) {
        guard admission.current == nil else { return send(["type": "error", "error": "already configured"]) }
        guard let path = message["socket"] as? String, path.hasPrefix("/"),
              let secret = (message["secret"] as? String).flatMap(HelperWire.unhex), secret.count >= 16 else {
            return send(["type": "error", "error": "configure needs an absolute socket path and a secret of at least 16 bytes"])
        }
        let hashes = Set((message["acpmux_cdhashes"] as? [String] ?? []).compactMap(HelperWire.unhex))
        admission.configure(AdmissionConfig(helperUID: geteuid(), acpmuxCDHashes: hashes,
                                            acpmuxRequirement: message["acpmux_requirement"] as? String,
                                            acpmuxDaemons: [], secret: secret))
        let socketServer = HelperSocketServer(path: path, admission: admission, inspector: inspector, tools: tools)
        do {
            try socketServer.start()
        } catch {
            return send(["type": "error", "error": "socket did not start: \(error)"])
        }
        server.withLock { $0 = socketServer }
        send(["type": "ready", "protocol": HelperWire.protocolVersion, "pid": Int(getpid()), "socket": path])
    }

    private func send(_ fields: [String: Any]) { write(HelperWire.line(fields)) }

    private func write(_ data: Data) {
        writeLock.withLock { _ in
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(output, raw.baseAddress! + offset, raw.count - offset)
                    if written <= 0 { if errno == EINTR { continue }; return }
                    offset += written
                }
            }
        }
    }
}
