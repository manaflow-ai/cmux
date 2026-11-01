import Darwin
import Foundation

/// Whether this Mac runs the stand-in acpmux the socket-peer tests start: a copy of `/usr/bin/nc`,
/// signed ad hoc, listening on a unix socket (AcpmuxSlowDaemonTests' `silentDaemon`,
/// AcpmuxServerPeerTests' deleted-file listener). Blacksmith's macOS 26.3 VMs end that copy before
/// it binds, so the tests that need it failed there in 0.03 s on every run since 2026-11-01 while
/// owned minis pass them. The probe never reads the socket's peer (the code under test): it only
/// asks whether the copy is still running once its socket file exists. When it cannot, it prints
/// why, and the tests that need it skip (https://github.com/manaflow-ai/cmux/issues/30978) instead of failing on the host.
enum CopiedListenerProbe {
    static let runs: Bool = probe()

    private static func probe() -> Bool {
        let root = URL(fileURLWithPath: "/tmp/clp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent("acpmux")
        let socket = root.appendingPathComponent("s.sock").path
        let errors = root.appendingPathComponent("stderr")
        let process = Process()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/nc"), to: copy)
            FileManager.default.createFile(atPath: errors.path, contents: nil)
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            // The tests' own command: re-signed ad hoc, then `exec` keeps the pid.
            process.arguments = ["-c", #"/usr/bin/codesign -f -s - "$0"; exec "$0" -dklU "$1""#, copy.path, socket]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = try FileHandle(forWritingTo: errors)
            try process.run()
        } catch {
            print("CopiedListenerProbe: the stand-in did not start: \(error)")
            return false
        }
        // wakeup-allow: bounded wait (60 s, as the tests' own) for the stand-in's socket file.
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning, !FileManager.default.fileExists(atPath: socket), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            let listening = FileManager.default.fileExists(atPath: socket)
            kill(process.processIdentifier, SIGKILL)
            if !listening { print("CopiedListenerProbe: a copied nc made no socket in 60 s") }
            return listening
        }
        // Foundation reaped it, so its status is read.
        let stderr = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
        let reason = process.terminationReason == .uncaughtSignal ? "signal" : "exit"
        print("CopiedListenerProbe: a copied nc ended before it listened (\(reason) \(process.terminationStatus)): \(stderr)")
        return false
    }
}
