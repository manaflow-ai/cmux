@testable import CmuxCloud
import CmuxCloudTui
import Darwin
import Foundation
import Testing

@Suite("Cloud machine link timeout recovery", .timeLimit(.minutes(1)))
struct CloudMachineLinkTimeoutRecoveryTests {
    @Test("a request deadline does not drop a healthy shared link")
    func requestTimeoutKeepsHealthyLink() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-link-request-timeout-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = "/tmp/cmux-link-request-timeout-\(UUID().uuidString.lowercased()).sock"
        let listener = try Self.makeListener(at: socketPath)
        defer { Darwin.close(listener); unlink(socketPath) }
        let client = root.appendingPathComponent("fake-cmux-tui")
        try """
        #!/bin/sh
        printf '%s\\n' '{"event":"connection-snapshot","local_socket":"\(socketPath)"}'
        exec tail -f /dev/null
        """.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        let requestReceived = CloudLinkFirstValue<Bool>()
        let server = Task.detached { Self.serve(listener: listener, respondsToPing: true, requestReceived: requestReceived) }
        let clock = CloudLinkTestClock()
        let link = CloudMachineLink(machineID: "healthy-timeout-machine", clientURL: client, paths: CloudTuiClientPaths(home: root), deadlineClock: clock)
        _ = try await link.connect(route: "ws://127.0.0.1:1337/v1/link", session: "cloud", carrier: true, timeout: .seconds(2))
        let request = Task { try await link.run(arguments: CloudTuiRequest("terminal.wait"), timeout: .seconds(1)) }
        _ = await requestReceived.result
        await clock.waitUntilSleeper(dueWithin: .seconds(1))
        clock.advance(by: .seconds(1))
        do {
            _ = try await request.value
            Issue.record("the intentionally short request must time out")
        } catch CloudMachineLink.LinkError.requestTimedOut {
            // Expected: the health probe below receives a response on the same channel.
        }
        #expect(await link.isConnected)
        _ = try await link.run(arguments: CloudTuiRequest("session.ping"), timeout: .seconds(1))
        #expect(await link.isConnected)
        await link.disconnect()
        server.cancel()
        await server.value
    }

    @Test("a timed out control request drops the wedged link for replacement")
    func timeoutDisconnectsLink() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-link-timeout-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = "/tmp/cmux-link-timeout-\(UUID().uuidString.lowercased()).sock"
        let listener = try Self.makeListener(at: socketPath)
        defer {
            Darwin.close(listener)
            unlink(socketPath)
        }

        let client = root.appendingPathComponent("fake-cmux-tui")
        try """
        #!/bin/sh
        printf '%s\\n' '{"event":"connection-snapshot","local_socket":"\(socketPath)"}'
        exec tail -f /dev/null
        """.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)

        let requestReceived = CloudLinkFirstValue<Bool>()
        let probeReceived = CloudLinkFirstValue<Bool>()
        let server = Task.detached(priority: .userInitiated) {
            Self.serve(listener: listener, respondsToPing: false, requestReceived: requestReceived, probeReceived: probeReceived)
        }
        let clock = CloudLinkTestClock()
        let link = CloudMachineLink(
            machineID: "timeout-machine",
            clientURL: client,
            paths: CloudTuiClientPaths(home: root),
            deadlineClock: clock
        )
        _ = try await link.connect(
            route: "ws://127.0.0.1:1337/v1/link",
            session: "cloud",
            carrier: true,
            timeout: .seconds(2)
        )

        let request = Task { try await link.run(arguments: CloudTuiRequest("session.ping"), timeout: .seconds(1)) }
        _ = await requestReceived.result
        await clock.waitUntilSleeper(dueWithin: .seconds(1))
        clock.advance(by: .seconds(1))
        _ = await probeReceived.result
        await clock.waitUntilSleeper(dueWithin: .seconds(2))
        clock.advance(by: .seconds(2))
        do {
            _ = try await request.value
            Issue.record("the unresponsive control request must time out")
        } catch CloudMachineLink.LinkError.requestTimedOut {
            // Expected: the timeout is the health boundary for this local link.
        }
        #expect(await link.isConnected == false)
        #expect(await link.state == .unavailable)

        server.cancel()
        await server.value
    }

    @Test("disconnect escalates a child that ignores TERM on the injected deadline")
    func disconnectKillsWedgedChild() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-link-shutdown-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = "/tmp/cmux-link-shutdown-\(UUID()).sock"
        let listener = try Self.makeListener(at: socketPath)
        defer { Darwin.close(listener); unlink(socketPath) }
        let client = root.appendingPathComponent("fake-cmux-tui")
        let pidFile = root.appendingPathComponent("pid")
        try """
        #!/bin/sh
        trap '' TERM
        echo $$ > '\(pidFile.path)'
        printf '%s\\n' '{"event":"connection-snapshot","local_socket":"\(socketPath)"}'
        exec tail -f /dev/null
        """.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        let server = Task.detached { Self.serve(listener: listener, respondsToPing: true) }
        let clock = CloudLinkTestClock()
        let link = CloudMachineLink(machineID: "wedged-child", clientURL: client,
                                    paths: CloudTuiClientPaths(home: root), deadlineClock: clock)
        _ = try await link.connect(route: "ws://127.0.0.1:1337/v1/link", session: "cloud", carrier: true, timeout: .seconds(2))
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let disconnect = Task { await link.disconnect() }
        await clock.waitUntilSleeper(dueWithin: .seconds(5))
        #expect(Darwin.kill(pid, 0) == 0)
        clock.advance(by: .seconds(5))
        await disconnect.value
        #expect(Darwin.kill(pid, 0) != 0)
        #expect(await link.isConnected == false)
        server.cancel()
        await server.value
    }

    private static func makeListener(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        return fd
    }

    private static func serve(listener: Int32, respondsToPing: Bool, requestReceived: CloudLinkFirstValue<Bool>? = nil, probeReceived: CloudLinkFirstValue<Bool>? = nil) {
        let peer = accept(listener, nil, nil)
        guard peer >= 0 else { return }
        defer { Darwin.close(peer) }
        var line = Data()
        var requestCount = 0
        var byte: UInt8 = 0
        while !Task.isCancelled {
            let count = withUnsafeMutableBytes(of: &byte) { Darwin.read(peer, $0.baseAddress, 1) }
            guard count == 1 else { return }
            if byte == 0x0A {
                guard
                    let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    let id = object["id"] as? String
                else {
                    line.removeAll(keepingCapacity: true)
                    continue
                }
                if let operation = object["operation"] as? String, operation == "session.ping" || operation == "terminal.wait" {
                    requestCount += 1
                    if requestCount == 1 { requestReceived?.resolve(true) }
                    if requestCount == 2 { probeReceived?.resolve(true) }
                }
                if (object["operation"] as? String == "session.ping" && respondsToPing) {
                    let response: [String: Any] = [
                        "protocol": "cmux.protocol/2", "type": "response", "id": id,
                        "ok": true, "result": [:],
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: response) {
                        _ = data.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, data.count) }
                        var newline = UInt8(0x0A)
                        _ = withUnsafeBytes(of: &newline) { Darwin.write(peer, $0.baseAddress, 1) }
                    }
                } else if object["operation"] as? String == "session.events",
                   let params = object["params"] as? [String: Any],
                   let streamID = params["stream_id"] as? String
                {
                    let response: [String: Any] = [
                        "protocol": "cmux.protocol/2", "type": "response", "id": id,
                        "ok": true, "result": ["stream_id": streamID],
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: response) {
                        _ = data.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, data.count) }
                        var newline = UInt8(0x0A)
                        _ = withUnsafeBytes(of: &newline) { Darwin.write(peer, $0.baseAddress, 1) }
                    }
                }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
    }
}
