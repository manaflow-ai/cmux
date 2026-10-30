// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import os
import os

private let controlLogger = Logger(subsystem: "com.cmuxterm.cua", category: "control")

/// The host control pipe: the helper's stdin (host -> helper) and stdout
/// (helper -> host), JSON lines. stdin EOF means the host quit, crashed or
/// stopped the helper: the helper removes its socket and exits. The pipe is
/// not reachable by any other process, so the secret travels here.
///
/// Whoever holds this pipe is not authenticated: a launcher's code
/// signature (or its parent's) says nothing about who writes it. So the pipe
/// carries no consent and runs no tool. Machine consent comes only over the
/// host socket (`HostConsentServer`), whose peer is checked per connection
/// by audit token; a `machine_consent` line here is ignored.
///
/// host -> helper:
///   {"type":"configure","socket":PATH,"host_socket":PATH,"host_secret":HEX,"secret":HEX,"acpmux_cdhashes":[HEX],"acpmux_requirement":STRING|null}
///   {"type":"register_acpmux","pid":N,"start_sec":N,"start_usec":N}
///   {"type":"request_permission","permission":"accessibility"|"screen_recording"}
/// helper -> host:
///   {"type":"ready","protocol":1,"pid":N,"socket":PATH,"host_socket":PATH}
///   {"type":"ack","of":"register_acpmux","ok":BOOL}
///   {"type":"error","error":STRING}
public final class HelperController: Sendable {
    private let input: Int32
    private let output: Int32
    private let tools: any ToolInvoking
    private let inspector: any PeerInspecting
    private let onExit: @Sendable (Int32) -> Void
    private let requestPermission: @Sendable (HelperPermission) async -> Bool
    /// Machine consent, asked of the host over the host socket; nil means no
    /// host answers and every call that needs consent is refused.
    private let consent: HostConsentChannel?
    private let hostCheck: any HostCodeChecking
    public let admission = AdmissionState()
    private let servers = OSAllocatedUnfairLock<(HelperSocketServer, HostConsentServer?)?>(initialState: nil)
    private let writeLock = OSAllocatedUnfairLock(initialState: ())

    public init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO, tools: any ToolInvoking,
                inspector: any PeerInspecting = KernelPeerInspector(),
                requestPermission: @escaping @Sendable (HelperPermission) async -> Bool = { await $0.request() },
                consent: HostConsentChannel? = nil,
                hostCheck: any HostCodeChecking = CmuxAppCodeCheck(),
                onExit: @escaping @Sendable (Int32) -> Void = { exit($0) }) {
        self.input = input
        self.output = output
        self.tools = tools
        self.inspector = inspector
        self.onExit = onExit
        self.requestPermission = requestPermission
        self.consent = consent
        self.hostCheck = hostCheck
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
        controlLogger.notice("host control pipe closed; stopping")
        shutdown()
        onExit(0)
    }

    public func shutdown() {
        let current = servers.withLockUnchecked { value -> (HelperSocketServer, HostConsentServer?)? in
            let old = value
            value = nil
            return old
        }
        current?.0.stop()
        current?.1?.stop()
    }

    private func handle(_ line: Data) {
        guard let message = HelperWire.object(line), let type = message["type"] as? String else {
            return send(["type": "error", "error": "invalid control message"])
        }
        switch type {
        case "configure": configure(message)
        case "request_permission":
            guard let name = message["permission"] as? String,
                  let permission = HelperPermission(rawValue: name) else {
                return send(["type": "error", "error": "unknown permission"])
            }
            Task { [self] in
                let granted = await requestPermission(permission)
                send(["type": "ack", "of": "request_permission", "permission": name, "granted": granted])
            }
        case "register_acpmux":
            var ok = false
            if let pid = message["pid"] as? Int, pid > 1, pid <= Int(Int32.max),
               let seconds = message["start_sec"] as? Int, seconds >= 0,
               let micros = message["start_usec"] as? Int, micros >= 0 {
                ok = admission.register(daemon: ProcessStamp(pid: pid_t(pid), startSeconds: UInt64(seconds),
                                                             startMicroseconds: UInt64(micros)))
            }
            send(["type": "ack", "of": "register_acpmux", "ok": ok])
        case "machine_consent":
            // Never trusted from the pipe: answers come only over the host socket.
            return
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
        let socketServer = HelperSocketServer(path: path, admission: admission, inspector: inspector, tools: tools,
                                              consent: consent ?? UnavailableConsent())
        // No host server without both: every consent check then refuses with host_unverified.
        let hostPath = (message["host_socket"] as? String).flatMap { $0.hasPrefix("/") && $0 != path ? $0 : nil }
        let hostSecret = (message["host_secret"] as? String).flatMap(HelperWire.unhex).flatMap { $0.count >= 16 ? $0 : nil }
        let hostServer: HostConsentServer? = if let hostPath, let hostSecret, let consent {
            HostConsentServer(path: hostPath, secret: hostSecret, channel: consent, check: hostCheck)
        } else {
            nil
        }
        do {
            try hostServer?.start()
            try socketServer.start()
        } catch {
            hostServer?.stop()
            return send(["type": "error", "error": "socket did not start: \(error)"])
        }
        servers.withLockUnchecked { $0 = (socketServer, hostServer) }
        var ready: [String: Any] = ["type": "ready", "protocol": HelperWire.protocolVersion, "pid": Int(getpid()),
                                    "socket": path]
        if let hostServer { ready["host_socket"] = hostServer.path }
        send(ready)
    }

    private func send(_ fields: [String: Any]) { write(HelperWire.line(fields)) }

    private func write(_ data: Data) {
        writeLock.withLockUnchecked { _ in
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
