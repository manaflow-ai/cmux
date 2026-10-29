// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Darwin
import Foundation
import os
import Testing

/// End to end through the real helper: the control pipe (`HelperController`
/// with `configure` and `register_acpmux`), the real helper socket and host
/// consent socket on disk, a fake app answering consent on the host socket,
/// and a client that speaks acpmux's bridge wire exactly
/// (cmux-tui/crates/acpmux/src/cua_v2.rs `Helper::admit`, `request`,
/// `require_tool_consent`). Faked: the peer facts of the bridge (its code and
/// ancestry, `Inspector`), the SecCode step of the app check
/// (`RecordingCheck(.verified)`), and the driver (a counting `GatedTools`).
@Suite struct BridgeConsentIntegrationTests {
    @Test(.timeLimit(.minutes(1))) func theBridgeFollowsDenyGrantRevokeAndARevokeAfterPreflight() async throws {
        let root = try #require(PrivateDirectory.userTemporaryRoot())
        let directory = root + "/cuai-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let input = Pipe(), output = Pipe()
        let channel = HostConsentChannel(timeout: .seconds(5))
        let tools = MachineConsentTests.GatedTools(gate: ConsentGate(authority: channel))
        let daemon = ProcessStamp(pid: 10, startSeconds: 1, startMicroseconds: 0)
        let controller = HelperController(input: input.fileHandleForReading.fileDescriptor,
                                          output: output.fileHandleForWriting.fileDescriptor,
                                          tools: tools, inspector: MachineConsentTests.Inspector(daemon: daemon),
                                          consent: channel, hostCheck: MachineConsentTests.RecordingCheck(.verified),
                                          onExit: { _ in })
        controller.start()
        defer { controller.shutdown() }
        let pipe = MachineConsentTests.Host(toHelper: input.fileHandleForWriting,
                                            fromHelper: output.fileHandleForReading.fileDescriptor)
        let secret = String(repeating: "ab", count: 32), hostSecret = String(repeating: "cd", count: 32)
        try pipe.send(["type": "configure", "socket": directory + "/h.sock", "host_socket": directory + "/c.sock",
                       "host_secret": hostSecret, "secret": secret, "acpmux_cdhashes": ["01"],
                       "acpmux_requirement": NSNull()])
        let ready = try await pipe.nextLine()
        #expect(ready["type"] as? String == "ready", "\(ready)")
        #expect(ready["host_secret"] == nil, "ready never echoes the host secret")
        try pipe.send(["type": "register_acpmux", "pid": 10, "start_sec": 1, "start_usec": 0])
        #expect(try await pipe.nextLine()["ok"] as? Bool == true)

        let app = try FakeApp(path: directory + "/c.sock", secret: hostSecret)
        defer { app.close() }
        let bridge = try Bridge(path: directory + "/h.sock", secret: secret)

        // Deny: the bridge refuses before calling, and a call sent anyway is
        // refused at execution.
        app.set(screen: "none", control: "none")
        #expect(try bridge.call("click") == .refusedByBridge)
        #expect(try bridge.callWithoutPreflight("click") == .refusedByHelper)
        // Screen only: observing runs, acting does not.
        app.set(screen: "granted", control: "none")
        #expect(try bridge.call("get_window_state") == .ran)
        #expect(try bridge.call("click") == .refusedByBridge)
        // Grant.
        app.set(screen: "granted", control: "granted")
        #expect(try bridge.call("click") == .ran)
        // Revoke.
        app.set(screen: "none", control: "none")
        #expect(try bridge.call("click") == .refusedByBridge)
        // Revoke after the bridge's preflight passed, before execution.
        app.set(screen: "granted", control: "granted")
        #expect(try bridge.call("click") { app.set(screen: "granted", control: "none") } == .refusedByHelper)

        #expect(tools.executed.withLock { $0 } == ["get_window_state", "click"], "nothing ran while denied")
        var refusals: [String] = []
        for await surface in app.refusals {
            refusals.append(surface)
            if refusals.count == 2 { break }
        }
        #expect(refusals == ["screen", "control"], "the helper's refusals reach the app")
    }

    enum Outcome: Equatable { case ran, refusedByBridge, refusedByHelper }

    /// acpmux's bridge on the admitted helper socket, one request at a time.
    final class Bridge {
        private let socket: LineSocket
        private var nextID = 1

        init(path: String, secret: String) throws {
            socket = try LineSocket(connecting: path)
            try socket.send(["secret": secret])
            #expect(try socket.read()["ok"] as? Bool == true)
        }

        /// `Helper::request("tools/call")`: `machine/consent`, `tools/list`
        /// for a screen-only grant, `require_tool_consent`, then the call.
        func call(_ name: String, afterPreflight: () -> Void = {}) throws -> Outcome {
            let status = try #require(try exchange(["method": "machine/consent"])["result"] as? [String: Any])
            let consent = status["consent"] as? [String: String] ?? [:]
            var readOnly = false
            if status["consentRequired"] as? Bool == true, consent["screen"] == "granted", consent["control"] == "none" {
                let inventory = try exchange(["method": "tools/list"])["result"]
                let tools = (inventory as? [[String: Any]]) ?? ((inventory as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
                let matching = tools.filter { $0["name"] as? String == name }
                readOnly = matching.count == 1
                    && ((matching[0]["annotations"] as? [String: Any])?["readOnlyHint"] as? NSNumber)
                        .map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } == true
            }
            let required = try #require(status["consentRequired"] as? Bool)
            if required, consent["screen"] != "granted" || (!readOnly && consent["control"] != "granted") {
                return .refusedByBridge
            }
            afterPreflight()
            return try callWithoutPreflight(name)
        }

        func callWithoutPreflight(_ name: String) throws -> Outcome {
            let reply = try exchange(["method": "tools/call", "name": name, "arguments": [String: Any]()])
            if reply["ok"] as? Bool == true { return .ran }
            #expect(reply["code"] as? String == "consent_required", "\(reply)")
            #expect(reply["reason"] == nil, "a person's refusal carries no reason")
            return .refusedByHelper
        }

        private func exchange(_ fields: [String: Any]) throws -> [String: Any] {
            let id = nextID
            nextID += 1
            try socket.send(fields.merging(["id": id]) { _, new in new })
            let reply = try socket.read()
            #expect(reply["id"] as? Int == id)
            return reply
        }
    }

    /// The cmux app on the host consent socket: answers each question from
    /// its daemon's current state and records refusals.
    final class FakeApp: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (screen: "none", control: "none"))
        let refusals: AsyncStream<String>
        private let refused: AsyncStream<String>.Continuation
        private let socket: LineSocket

        init(path: String, secret: String) throws {
            (refusals, refused) = AsyncStream<String>.makeStream()
            socket = try LineSocket(connecting: path, receiveTimeout: 0)
            try socket.send(["secret": secret])
            #expect(try socket.read()["ok"] as? Bool == true, "the helper accepted the app")
            Thread { [self] in answer() }.start()
        }

        func set(screen: String, control: String) { state.withLock { $0 = (screen, control) } }

        /// Ends the answering thread (its read returns at shutdown).
        func close() { socket.shutdown() }

        private func answer() {
            while let line = try? socket.read() {
                switch line["type"] as? String {
                case "machine_consent":
                    let (screen, control) = state.withLock { $0 }
                    try? socket.send(["type": "machine_consent", "id": line["id"] ?? NSNull(), "ok": true,
                                      "result": ["consentRequired": true,
                                                 "consent": ["screen": screen, "control": control]]])
                case "consent_refused":
                    refused.yield(line["surface"] as? String ?? "")
                default: break
                }
            }
            refused.finish()
        }
    }

    /// A connected Unix socket that reads and writes JSON lines.
    final class LineSocket: @unchecked Sendable {
        private let descriptor: Int32
        private var buffer = HelperWire.LineBuffer()
        private var pending: [Data] = []

        /// `receiveTimeout` seconds per read (0: none).
        init(connecting path: String, receiveTimeout: Int = 5) throws {
            descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            try #require(descriptor >= 0)
            var timeout = timeval(tv_sec: receiveTimeout, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: path.utf8)
                raw[path.utf8.count] = 0
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            let connectErrno = errno
            try #require(connected == 0, "connect \(path): errno \(connectErrno)")
        }

        deinit { close(descriptor) }

        func shutdown() { Darwin.shutdown(descriptor, SHUT_RDWR) }

        func send(_ fields: [String: Any]) throws {
            let line = HelperWire.line(fields)
            try #require(line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == line.count)
        }

        func read() throws -> [String: Any] {
            while pending.isEmpty {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(descriptor, &chunk, chunk.count)
                guard count > 0 else { throw ToolError("the socket closed or timed out") }
                let lines = buffer.append(Data(chunk.prefix(count)))
                pending += try #require(lines)
            }
            return try #require(HelperWire.object(pending.removeFirst()))
        }
    }
}
