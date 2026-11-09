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
        #expect(signals.first == .started && signals.contains(.restoring), "\(signals)")
        // The new owner's ready ends the replace (a late write report may follow it: #39750).
        #expect(signals.contains(.ready(pid: 4242)) && !signals.contains(.exited), "\(signals)")
    }

    @Test func aFailedReplaceReportsTheFailure() async throws {
        let (launcher, seen, root) = try Self.launcher(lines: [], status: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) { try await launcher.replaceUnresponsive() }
        #expect(seen.all.last == .exited)
    }
}
