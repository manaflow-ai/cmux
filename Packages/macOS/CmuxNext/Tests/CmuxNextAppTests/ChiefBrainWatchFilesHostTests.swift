import Darwin
import Foundation
@testable import CmuxNextHomeEngine
import Testing

/// In a DEV build that runs the brain host under "cmux Files (dev)" (docs/cmux-files-host.md), the
/// launch prints the helper launcher's pid, and the host it starts (the launcher's grandchild:
/// launcher, staged helper host, optchat-chief) writes its own pid into the Chief home's lock. The
/// watch must still hear the host take the lock, or Home's default Chief reads "no brain" for the
/// whole launch (review of #45912).
@MainActor @Suite(.serialized) struct ChiefBrainWatchFilesHostTests {
    @Test func aHostStartedUnderTheHelperIsWatchedOnceItTakesTheLock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-watch-files-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = ChiefHome(root: root, isolated: true)
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let hostPIDFile = root.appendingPathComponent("host.pid")

        // A stand-in launcher whose grandchild is the stand-in host, as under the helper.
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", #"/bin/sh -c 'sleep 30 & echo $! > "$1"; wait' inner "$0" & wait"#, hostPIDFile.path]
        try launcher.run()
        var hostPID: pid_t = 0
        let started = ContinuousClock.now + .seconds(5)
        while hostPID == 0, ContinuousClock.now < started {
            hostPID = (try? String(contentsOf: hostPIDFile, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            if hostPID == 0 { try await Task.sleep(for: .milliseconds(20)) }
        }
        try #require(hostPID > 0)
        defer {
            kill(hostPID, SIGKILL)
            launcher.terminate()
        }

        var seen: [pid_t?] = []
        let watch = ChiefBrainWatch(home: home, restart: { nil }, watching: { seen.append($0) },
                                    isChiefHost: { $0 == hostPID },
                                    isFilesHostLauncher: { $0 == launcher.processIdentifier })
        // The launch printed the launcher's pid; the lock does not name the host yet.
        watch.watch(launcher.processIdentifier)
        #expect(seen == [launcher.processIdentifier])

        try Data("\(hostPID)\n".utf8).write(to: state.appendingPathComponent("host.lock"))
        let deadline = ContinuousClock.now + .seconds(5)
        while seen.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(seen == [launcher.processIdentifier, hostPID], "the host the launcher started took the lock: it is watched")
        watch.stop()
    }

    /// Without the helper, a host the lock names that is not the launched one (another build's,
    /// the CLI's) is not taken for it: the watch keeps waiting for its own host.
    @Test func aHostOutsideTheLaunchIsNotTakenForIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-watch-files-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = ChiefHome(root: root, isolated: true)
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sleep")
        launcher.arguments = ["30"]
        try launcher.run()
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        defer {
            launcher.terminate()
            other.terminate()
        }
        var seen: [pid_t?] = []
        let watch = ChiefBrainWatch(home: home, restart: { nil }, watching: { seen.append($0) },
                                    isChiefHost: { $0 == other.processIdentifier })
        watch.watch(launcher.processIdentifier)
        try Data("\(other.processIdentifier)\n".utf8).write(to: state.appendingPathComponent("host.lock"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(seen == [launcher.processIdentifier], "an unrelated host is not the launched one")
        watch.stop()
    }
}
