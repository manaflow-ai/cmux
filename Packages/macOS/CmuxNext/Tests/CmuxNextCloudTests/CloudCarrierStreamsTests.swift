@testable import CmuxNextCloud
import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// Open Desktop's carrier dials end with the account (#37210): ``CloudCarrierStreams/endAll()``, which
/// CloudService runs on sign-out, an account or team switch and Cloud turned off, closes every held stream
/// and kills every dial child still dialing, and fences the connectors made before it.
@Suite struct CloudCarrierStreamsTests {
    /// A held stream ends as a remote close would (its read answers nil), its child is gone, and the same
    /// connector's next open is refused without spawning; a connector made after the end opens again.
    @Test func anEndClosesTheHeldStreamAndFencesItsConnector() async throws {
        // The stand-in records each launch and its pid, answers the dial, then holds the stream open.
        let cli = try Self.standIn("d=$(dirname \"$0\")\necho launched >> \"$d/launches\"\nprintf '%s' $$ > \"$d/pid\"\nprintf '{\"ok\":true,\"route\":\"carrier\"}\\n' >&2\nexec cat >/dev/null\n")
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let streams = CloudCarrierStreams()
        let dial = try #require(CloudCarrierDial(machine: "vm_abc123", service: .desktop))
        let connector = CloudCarrierDial.Connector(cli: cli, dial: dial, streams: streams) { [:] }
        let stream = try await connector.open()
        #expect(streams.count == 1)
        let pid = try #require(pid_t(try String(contentsOf: folder.appendingPathComponent("pid"), encoding: .utf8)))
        let reader = Task { await stream.read() }

        await streams.endAll().value
        #expect(await reader.value == nil, "the stream outlived the account")
        #expect(Self.isGone(pid), "the dial child outlived the account")
        #expect(streams.count == 0)

        await #expect(throws: CloudLinkError.disconnected(reason: "closed")) { _ = try await connector.open() }
        #expect(try Self.launches(folder) == 1, "a fenced open spawned a dial")

        let next = try await CloudCarrierDial.Connector(cli: cli, dial: dial, streams: streams) { [:] }.open()
        #expect(streams.count == 1)
        next.close()
        #expect(streams.count == 0)
        #expect(try Self.launches(folder) == 2)
    }

    /// An end while a dial is still waiting for its answer kills that child at once (it would hold the
    /// token up to the dial's deadline) and the open fails as closed.
    @Test func anEndDuringTheDialKillsTheChildAndRefusesTheOpen() async throws {
        // The stand-in never answers: it blocks reading its stdin (a shell builtin, no grandchild).
        let cli = try Self.standIn("d=$(dirname \"$0\")\nprintf '%s' $$ > \"$d/pid\"\nread -r line\nprintf '{\"ok\":true,\"route\":\"carrier\"}\\n' >&2\n")
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let streams = CloudCarrierStreams()
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .desktop)),
                                                   streams: streams) { [:] }
        let open = Task { try await connector.open() }
        let pidFile = folder.appendingPathComponent("pid")
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let pid = try #require(pid_t(try String(contentsOf: pidFile, encoding: .utf8)))
        #expect(streams.count == 1, "the dialing child is not held")

        let ended = ContinuousClock.now
        await streams.endAll().value
        await #expect(throws: CloudLinkError.disconnected(reason: "closed")) { _ = try await open.value }
        #expect(ended.duration(to: .now) < .seconds(10), "the open waited out the dial instead of ending")
        #expect(Self.isGone(pid), "the dialing child outlived the account")
        #expect(streams.count == 0)
    }

    /// An end while an open waits for its access token spawns nothing (it would dial for the old account).
    @Test func anEndDuringTheTokenSpawnsNothing() async throws {
        let cli = try Self.standIn("d=$(dirname \"$0\")\necho launched >> \"$d/launches\"\nprintf '{\"ok\":true,\"route\":\"carrier\"}\\n' >&2\nexec cat >/dev/null\n")
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let streams = CloudCarrierStreams()
        let (asked, askedOnce) = AsyncStream.makeStream(of: Void.self)
        let (token, tokenOnce) = AsyncStream.makeStream(of: Void.self)
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .desktop)),
                                                   streams: streams) {
            askedOnce.yield()
            for await _ in token { break }
            return ["CMUX_CLOUD_ACCESS_TOKEN": "old-account"]
        }
        let open = Task { try await connector.open() }
        for await _ in asked { break }
        await streams.endAll().value
        tokenOnce.yield()
        await #expect(throws: CloudLinkError.disconnected(reason: "closed")) { _ = try await open.value }
        #expect(try Self.launches(folder) == 0, "a fenced open spawned a dial")
    }

    /// Reaped: no process has the pid any more.
    private static func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    private static func launches(_ folder: URL) throws -> Int {
        let file = folder.appendingPathComponent("launches")
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count
    }

    private static func standIn(_ body: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ccs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cli = folder.appendingPathComponent("cmux-tui")
        try ("#!/bin/sh\n" + body).write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return cli
    }
}
