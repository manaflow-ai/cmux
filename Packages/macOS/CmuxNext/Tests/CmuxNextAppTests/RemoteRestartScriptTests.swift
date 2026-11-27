import CmuxNextRemote
import Foundation
import Testing

/// cx-3r9mt at the install's restart boundary: after a remote install the restart script must stop
/// the machine's session daemon so the next link starts the new build. A daemon that re-executed
/// itself shows `/proc/self/exe` as its argv[0] (no "cmux-tui" in its ps args); the script runs here
/// against a real process shaped like that, and must SIGTERM it, and leave any other process alone.
@Suite(.serialized)
struct RemoteRestartScriptTests {
    /// A small program built here and named `name` (a copied system binary is not allowed to run),
    /// started with argv[0] `/proc/self/exe --headless --session <session>`: its ps args then read
    /// like the re-executed daemon's, and only its executable names cmux-tui.
    private func daemonLike(_ root: URL, session: String, name: String = "cmux-tui") throws -> Process {
        let binary = root.appendingPathComponent(name)
        let source = root.appendingPathComponent("\(name).c")
        try "#include <unistd.h>\nint main(void) { sleep(120); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = ["-o", binary.path, source.path]
        try cc.run()
        cc.waitUntilExit()
        try #require(cc.terminationStatus == 0, "cc could not build the stand-in daemon")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "exec -a \"/proc/self/exe --headless --session \(session)\" \"$0\" 120", binary.path]
        try process.run()
        // Only once bash exec'd the program do the ps args read like the daemon's (before, bash's
        // own args name the cmux-tui path and the script would stop bash instead).
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !Self.args(of: process.processIdentifier).hasPrefix("/proc/self/exe") { usleep(20_000) } // bounded
        try #require(Self.args(of: process.processIdentifier).hasPrefix("/proc/self/exe"))
        return process
    }

    private static func args(of pid: Int32) -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "args=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        ps.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runScript(_ script: String) throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script]
        // The remote's own PATH has the system tools (lsof is in /usr/sbin on a Mac).
        shell.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        try shell.run()
        shell.waitUntilExit()
    }

    private func exited(_ process: Process, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline { usleep(50_000) } // test harness poll, bounded
        return !process.isRunning
    }

    @Test func aReExecutedSessionDaemonIsStoppedAndAnotherProcessIsNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rrs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try SSHHost(destination: SSHDestination(parsing: "drill"), remoteBinary: root.appendingPathComponent("absent").path)
        let daemon = try daemonLike(root, session: host.session)
        defer { if daemon.isRunning { daemon.terminate() } }
        // A process of another program with the same argv: never signalled.
        let other = try daemonLike(root, session: host.session, name: "other-tool")
        defer { if other.isRunning { other.terminate() } }
        try runScript(RemoteInstallPlan.restartScript(host: host, daemonPID: daemon.processIdentifier))
        try runScript(RemoteInstallPlan.restartScript(host: host, daemonPID: other.processIdentifier))
        let stopped = exited(daemon, within: 5)
        #expect(stopped, "the re-executed session daemon was not stopped")
        if stopped { #expect(daemon.terminationReason == .uncaughtSignal && daemon.terminationStatus == SIGTERM) }
        #expect(other.isRunning, "a process that is not cmux-tui was signalled")
    }
}
