@testable import CmuxNextCloud
import Foundation
import Testing

/// ``CloudCarrierServe`` as the executor of ``ServeMachine``, with stand-in `cmux-tui` scripts: the fence read at
/// every event and the socket lease shared by serve instances of one machine.
@Suite struct CloudCarrierServeExecutorTests {
    /// An account end lands before a queued ready line: the fence is read before each event, so the ready line
    /// hands the old account's socket to no one, even before the hold closure's own `accountEnded` hop arrives.
    @Test func aReadyLineAfterAnAccountEndHandsOutNoSocket() async throws {
        // The child writes its ready line only on `go`; the test delivers one itself instead.
        let cli = try Self.standIn("d=$(dirname \"$0\")\necho launched >> \"$d/launches\"\nwhile [ ! -f \"$d/go\" ]; do sleep 0.05; done\n")
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let streams = CloudCarrierStreams()
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux)), streams: streams) {
            ["CMUX_CLOUD_ACCESS_TOKEN": "old-account"]
        }
        let socket = folder.appendingPathComponent("cmux-link-0123456789ab.sock").path
        let serve = CloudCarrierServe(connector: connector, socket: socket) { _ in }
        let connect = Task { try await serve.socketPath(keepingRefusal: true) }
        let deadline = ContinuousClock.now + .seconds(5)
        while await serve.state != .spawning(1, child: 1, sentToken: "old-account"), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await serve.state == .spawning(1, child: 1, sentToken: "old-account"))
        streams.endAll()
        await serve.send(.readyLine(child: 1, socket: socket, policy: nil))
        await #expect(throws: CloudLinkError.disconnected(reason: "closed")) { _ = try await connect.value }
        #expect(await serve.state == .stopping(child: 1, .accountEnded))
        try Data().write(to: folder.appendingPathComponent("go"))
    }

    /// Two replacement serves for one socket both wait on the old child's exit: only one claims the socket and
    /// launches; the other launches once that one's child exited. No two children ever run at once.
    @Test func twoReplacementsLaunchOneAtATime() async throws {
        // `lock` is held from launch to exit: a second child that finds it taken records an overlap. Each child
        // waits for `go`, then serves until its stdin closes.
        let cli = try Self.standIn("""
            d=$(dirname "$0")
            echo launched >> "$d/launches"
            mkdir "$d/lock" 2>/dev/null || echo overlap >> "$d/launches"
            while [ ! -f "$d/go" ]; do sleep 0.05; done
            printf '{"ok":true,"socket":"%s","route":"carrier"}\\n' "$6" >&2
            cat >/dev/null
            rmdir "$d/lock"
            echo exited >> "$d/launches"

            """)
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appendingPathComponent("cmux-link-0123456789ab.sock").path
        let leases = CloudCarrierLeases()
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) { ["CMUX_CLOUD_ACCESS_TOKEN": "t"] }
        let first = CloudCarrierServe(connector: connector, socket: socket, leases: leases) { _ in }
        let launches = folder.appendingPathComponent("launches")
        let firstConnect = Task { try await first.socketPath() }
        var deadline = ContinuousClock.now + .seconds(5)
        while (try? String(contentsOf: launches, encoding: .utf8)) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await first.stop()
        _ = try? await firstConnect.value
        let replacements = [CloudCarrierServe(connector: connector, socket: socket, leases: leases) { _ in },
                            CloudCarrierServe(connector: connector, socket: socket, leases: leases) { _ in }]
        let connects = replacements.map { serve in Task { try await serve.socketPath() } }
        try await Task.sleep(for: .milliseconds(300))
        for serve in replacements { #expect(await serve.state == .claiming(1)) }
        try Data().write(to: folder.appendingPathComponent("go"))
        // One of them gets ready; the other is still waiting for the socket.
        deadline = ContinuousClock.now + .seconds(5)
        var ready: CloudCarrierServe?
        while ready == nil, ContinuousClock.now < deadline {
            for serve in replacements { if await serve.refreshing { ready = serve } }
            try await Task.sleep(for: .milliseconds(10))
        }
        let winner = try #require(ready)
        try await Task.sleep(for: .milliseconds(300))
        let waiting = try #require(replacements.first { $0 !== winner })
        #expect(await waiting.state == .claiming(1), "both replacements claimed the socket")
        // The winner stops; its child exits and the other launches.
        await winner.stop()
        for connect in connects { #expect(try await withDeadline(.seconds(10), label: "replacement") { try await connect.value } == socket) }
        await waiting.stop()
        let text = try String(contentsOf: launches, encoding: .utf8)
        #expect(!text.contains("overlap"), "two serve children ran at once: \(text)")
        #expect(text.components(separatedBy: "launched").count - 1 == 3)
    }

    private static func standIn(_ body: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ccx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cli = folder.appendingPathComponent("cmux-tui")
        try ("#!/bin/sh\n" + body).write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return cli
    }
}
