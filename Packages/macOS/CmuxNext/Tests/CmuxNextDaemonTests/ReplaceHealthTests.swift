import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// Codex's review of #39247 at 2903cec (F1): "Restart cmux-tui" and the automatic restart run
/// `server ensure --replace-unresponsive`, and app health reads it as it reads an ensure: the new
/// owner's restore progress, then its ready (with the new pid) or the failure. Without it app
/// health kept the old owner's stuck state and no restore held the next automatic replace.
@Suite struct ReplaceHealthTests {
    /// The signals the launcher's health sink received.
    final class Seen: Sendable {
        let signals = Mutex<[DaemonHealthSink.Signal]>([])
        var all: [DaemonHealthSink.Signal] { signals.withLock { $0 } }
    }

    /// A stand-in `cmux-tui` whose `server ensure` prints `lines` (a pause after each, so the runner's
    /// write watch sees the restore line before the result) and exits `status`.
    static func launcher(lines: [String], status: Int32) throws -> (DaemonLauncher, Seen, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("replace-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("cmux-tui")
        let script = "#!/bin/sh\n" + lines.map { "printf '%s\\n' '\($0)'\nsleep 0.3\n" }.joined() + "exit \(status)\n"
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        var launcher = DaemonLauncher(configuration: .init(binary: binary, session: "replace-health", stateDirectory: root.appendingPathComponent("state"),
                                                           binaryIsBundled: true),
                                      environment: { [:] })
        let sink = DaemonHealthSink()
        let seen = Seen()
        sink.bind { signal in seen.signals.withLock { $0.append(signal) } }
        launcher.health = sink
        return (launcher, seen, root)
    }

    @Test func aReplaceReportsTheNewOwnersRestoreAndReady() async throws {
        let (launcher, seen, root) = try Self.launcher(lines: [
            #"{"restore":{"phase":"terminals","done":1,"total":4,"elapsed_ms":900}}"#,
            #"{"status":"replaced","session":"replace-health","socket":"/tmp/replace-health.sock","pid":4242,"generation":"g2"}"#,
        ], status: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let ensured = try await launcher.replaceUnresponsive()
        #expect(ensured.pid == 4242)
        let signals = seen.all
        // The new owner's restore starts it, then its ready ends the replace (a late write report may follow: #39750).
        let started = try #require(signals.firstIndex(of: .started), "\(signals)")
        let ready = try #require(signals.firstIndex(of: .ready(pid: 4242)), "\(signals)")
        #expect(started < ready && signals.contains(.restoring) && !signals.contains(.exited), "\(signals)")
    }

    @Test func aFailedStartReportsTheFailure() async throws {
        let (launcher, seen, root) = try Self.launcher(lines: [], status: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) { try await launcher.replaceUnresponsive() }
        #expect(seen.all.last == .exited)
    }

    /// A refused replace (`server.replace_*`, exit 3) stopped nothing: the old owner still runs, so its
    /// restore hold stays.
    @Test func aRefusedReplaceLeavesTheOldOwnersState() async throws {
        let (launcher, seen, root) = try Self.launcher(lines: [], status: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        let refusal = root.appendingPathComponent("cmux-tui")
        let script = "#!/bin/sh\nprintf '%s\\n' '{\"code\":\"server.replace_not_stuck\",\"message\":\"the owner answers\"}' >&2\nexit 3\n"
        try Data(script.utf8).write(to: refusal)
        await #expect(throws: DaemonLauncher.ReplaceRefusal.self) { try await launcher.replaceUnresponsive() }
        #expect(seen.all.isEmpty, "\(seen.all)")
    }

    /// Codex's review of #39247 at f02e048 (F3): the automatic restart checked app health's hold before
    /// its claim, so restore progress that came since could still be replaced. The launcher asks again
    /// just before it starts the replace, and a held replace runs nothing.
    @Test func aReplaceHeldAtItsStartRunsNothing() async throws {
        let (launcher, seen, root) = try Self.launcher(lines: [
            #"{"status":"replaced","session":"replace-health","socket":"/tmp/replace-health.sock","pid":4242,"generation":"g2"}"#,
        ], status: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let ran = root.appendingPathComponent("ran")
        let script = "#!/bin/sh\ntouch '\(ran.path)'\nexit 1\n"
        try Data(script.utf8).write(to: root.appendingPathComponent("cmux-tui"))
        await #expect(throws: DaemonLauncher.ReplaceRefusal(code: DaemonLauncher.ReplaceRefusal.heldCode, message: "the owner is restoring and still makes progress")) {
            try await launcher.replaceUnresponsive(unlessHeld: { true })
        }
        #expect(!FileManager.default.fileExists(atPath: ran.path), "the held replace started server ensure")
        #expect(seen.all.isEmpty, "\(seen.all)")
    }
}
