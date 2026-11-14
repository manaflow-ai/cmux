@testable import CmuxNextCrashReporting
import Darwin
import Foundation
import Testing

/// #22844: the out-of-process crash watcher. A stand-in process (`/bin/sleep`) plays the stuck
/// app; this test holds the pipe's write end as the app does.
@Suite(.serialized)
struct CrashWatcherTests {
    private static func spawnStandIn() throws -> pid_t {
        var pid: pid_t = 0
        let strings: [String] = ["/bin/sleep", "600"]
        let arguments: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        let status = arguments.withUnsafeBufferPointer { posix_spawn(&pid, "/bin/sleep", nil, nil, $0.baseAddress, nil) }
        try #require(status == 0, "posix_spawn of the stand-in failed: \(status)")
        return pid
    }

    /// Waits for `pid` (a child of this test) to end, up to `seconds`; its wait status, or nil.
    private static func end(of pid: pid_t, within seconds: Double) async -> Int32? {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(Int(seconds * 1000))
        var status: Int32 = 0
        while clock.now < deadline {
            if waitpid(pid, &status, WNOHANG) == pid { return status }
            try? await Task.sleep(for: .milliseconds(100)) // test harness polling a child process
        }
        return nil
    }

    private static func stop(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    private static func sampleFile() -> String {
        FileManager.default.temporaryDirectory.appending(path: "crash-watcher-\(UUID().uuidString).txt").path
    }

    @Test func anArmedWatcherEndsAStuckProcessWithSIGKILLAfterItsSeconds() async throws {
        let app = try Self.spawnStandIn()
        defer { Self.stop(app) }
        let sample = Self.sampleFile()
        defer { unlink(sample) }
        let watcher = try CrashWatcher(sampleFile: sample, seconds: 2).spawn(watching: app)
        defer { close(watcher.writeEnd) }
        var byte: UInt8 = 0x63
        let started = ContinuousClock.now
        #expect(write(watcher.writeEnd, &byte, 1) == 1)
        let status = try #require(await Self.end(of: app, within: 30), "the watcher did not end the stuck process")
        #expect(status & 0x7f == SIGKILL, "wait status \(status)")
        #expect(ContinuousClock.now - started >= .seconds(2), "the watcher acted before its seconds")
        // No check of the sample file here: macOS refuses to sample a platform binary such as
        // /bin/sleep. crash-ends-app-gate.py's "suspended" run checks it on the app.
        #expect(await Self.end(of: watcher.pid, within: 10) != nil, "the watcher did not exit after the kill")
    }

    /// A stand-in `sample` that never returns (as `sample` did on a loaded CI runner, run 42568653071).
    private static func hangingSampleTool() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "crash-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tool = directory.appending(path: "sample")
        try "#!/bin/zsh -f\nexec /bin/sleep 1000\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    @Test func aSampleThatNeverReturnsDoesNotKeepTheStuckProcessAlive() async throws {
        let app = try Self.spawnStandIn()
        defer { Self.stop(app) }
        let tool = try Self.hangingSampleTool()
        defer { try? FileManager.default.removeItem(at: tool.deletingLastPathComponent()) }
        let sample = Self.sampleFile()
        defer { unlink(sample) }
        let watcher = try CrashWatcher(sampleFile: sample, seconds: 2, sampleTool: tool.path).spawn(watching: app)
        defer {
            close(watcher.writeEnd)
            // The watcher leads its own process group: this also ends a stand-in sample it left running.
            kill(-watcher.pid, SIGKILL)
            var status: Int32 = 0
            waitpid(watcher.pid, &status, 0)
        }
        var byte: UInt8 = 0x63
        let started = ContinuousClock.now
        #expect(write(watcher.writeEnd, &byte, 1) == 1)
        // 2 s of watcher seconds plus the sample bound, with room for a loaded runner.
        let status = try #require(await Self.end(of: app, within: 15), "a sample that never returns kept the stuck process alive")
        #expect(status & 0x7f == SIGKILL, "wait status \(status)")
        #expect(ContinuousClock.now - started >= .seconds(2), "the watcher acted before its seconds")
        #expect(await Self.end(of: watcher.pid, within: 10) != nil, "the watcher did not exit after the kill")
    }

    @Test func aNormalEndWithNoArmLeavesTheProcessAndEndsTheWatcher() async throws {
        let app = try Self.spawnStandIn()
        defer { Self.stop(app) }
        let watcher = try CrashWatcher(sampleFile: Self.sampleFile(), seconds: 1).spawn(watching: app)
        close(watcher.writeEnd)
        #expect(await Self.end(of: watcher.pid, within: 10) != nil, "the watcher outlived the pipe's writer")
        #expect(kill(app, 0) == 0, "the watcher signalled a process that never began a crash")
    }

    @Test func aCrashPathThatEndsInTimeIsNotSignalled() async throws {
        let app = try Self.spawnStandIn()
        defer { Self.stop(app) }
        let watcher = try CrashWatcher(sampleFile: Self.sampleFile(), seconds: 3).spawn(watching: app)
        var byte: UInt8 = 0x63
        #expect(write(watcher.writeEnd, &byte, 1) == 1)
        #expect(write(watcher.writeEnd, &byte, 1) == 1, "a second arm")
        // The writer's end (the app ending) closes the pipe before the watcher's seconds.
        close(watcher.writeEnd)
        #expect(await Self.end(of: watcher.pid, within: 10) != nil, "the watcher did not exit on EOF")
        #expect(kill(app, 0) == 0, "the watcher signalled a process whose crash path ended")
    }
}
