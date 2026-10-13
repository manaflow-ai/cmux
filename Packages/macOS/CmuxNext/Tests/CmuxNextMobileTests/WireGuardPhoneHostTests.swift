import CmuxWireGuard
import CmuxWireGuardPairing
import Darwin
import Foundation
import Testing
@testable import CmuxNextMobile

/// A Unix socket that answers every request line with `{"id":<id>,"ok":true,"data":{"echo":<cmd>}}`.
private final class FakeDaemonSocket: @unchecked Sendable {
    let path: String
    private let fd: Int32

    init() throws {
        let path = NSTemporaryDirectory() + "wg-fake-\(UUID().uuidString.prefix(8)).sock"
        self.path = path
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            _ = path.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count))) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(sock, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        fd = sock
        Thread.detachNewThread {
            while true {
                let client = accept(sock, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { Self.serve(client) }
            }
        }
    }

    deinit {
        Darwin.close(fd)
        unlink(path)
    }

    private static func serve(_ client: Int32) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                let response: [String: Any] = ["id": request["id"] ?? NSNull(), "ok": true,
                                               "data": ["echo": request["cmd"] ?? ""]]
                var data = try! JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
                data.append(0x0A)
                _ = data.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
            }
        }
        Darwin.close(client)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct WireGuardPhoneHostTests {
    private func readLine(_ stream: SocketStream) async throws -> [String: Any] {
        var buffer = Data()
        while !buffer.contains(0x0A) {
            guard let chunk = try await stream.read() else { break }
            buffer.append(chunk)
        }
        let line = buffer.prefix { $0 != 0x0A }
        return try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    @Test func phonePairsReachesTheDaemonUnderPolicyAndCanBeRevoked() async throws {
        let daemon = try FakeDaemonSocket()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wg-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = daemon.path
        let host = WireGuardPhoneHost(stateDirectory: directory, hostName: "Test Mac",
                                      daemonSocketPath: { path }, onChange: { _ in })
        await host.start()
        let started = await host.snapshot()
        #expect(started.running)
        let port = try #require(started.listenPort)

        var invitation = try await host.makeInvitation()
        #expect(invitation.hostName == "Test Mac")
        invitation.endpoints = ["127.0.0.1:\(port)"]

        let phoneKey = WireGuardKey()
        var paired = try await WireGuardPairingClient().pair(invitation: invitation, permanentKey: phoneKey,
                                                              deviceName: "Test iPhone", deviceModel: "iPhone")
        #expect(paired.address == "10.77.0.2")
        #expect(paired.lastGoodEndpoint == "127.0.0.1:\(port)")
        let afterPairing = await host.snapshot()
        #expect(afterPairing.phones.map(\.name) == ["Test iPhone"])
        #expect(afterPairing.justPaired?.publicKey == phoneKey.publicKey)

        // The invitation is single use: its bootstrap peer is gone.
        await #expect(throws: PairingError.unreachable) {
            _ = try await WireGuardPairingClient().pair(invitation: invitation, permanentKey: WireGuardKey(),
                                                        deviceName: "Second", deviceModel: "iPhone")
        }

        paired.endpoints = ["127.0.0.1:\(port)"]
        let link = try PairedHostLink(host: paired, privateKey: phoneKey)
        let lane = try await link.connect(port: OverlayPlan().daemonPort)
        try await lane.write(Data(#"{"id":1,"cmd":"identify"}"#.utf8 + [0x0A]))
        let identify = try await readLine(lane)
        #expect(identify["ok"] as? Bool == true)
        #expect((identify["data"] as? [String: Any])?["echo"] as? String == "identify")

        // DaemonLanePolicy still applies to WireGuard phones.
        try await lane.write(Data(#"{"id":2,"cmd":"shutdown-daemon"}"#.utf8 + [0x0A]))
        let refused = try await readLine(lane)
        #expect(refused["ok"] as? Bool == false)
        #expect(refused["error_code"] as? String == "forbidden")
        lane.close()

        // A restarted host keeps the pairing.
        await host.stop()
        await host.start()
        let relaunched = try await link.connect(port: OverlayPlan().daemonPort)
        try await relaunched.write(Data(#"{"id":3,"cmd":"ping"}"#.utf8 + [0x0A]))
        #expect(try await readLine(relaunched)["ok"] as? Bool == true)
        relaunched.close()

        let phoneID = try #require(paired.deviceID as String?)
        try await host.revoke(phoneID: phoneID)
        #expect(await host.snapshot().phones.isEmpty)
        await #expect(throws: PairingError.unreachable) {
            _ = try await link.connect(port: OverlayPlan().daemonPort, perEndpoint: .seconds(2))
        }
        link.close()
        await host.stop()
    }
}
