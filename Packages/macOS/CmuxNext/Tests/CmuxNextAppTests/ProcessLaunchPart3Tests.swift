@testable import CmuxNextBrowserCore
@testable import CmuxNextChromiumRuntime
import CmuxNextCompat
@testable import CmuxNextServerHelper
@testable import CmuxNextUpdater
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// Task p02-threads-040 (plans/cmux-next/chrome-parity/p02-threads.md, INV-3): the web update unpack, the Chromium
/// runtime's tar, the Mail verification script and the server helper's fixes start their children off the caller
/// (AsyncProcess, or the helper's own utility thread), never on the caller's thread (Chromium's
/// content/browser/child_process_launcher_helper.cc). Each wrapper reports its spawns through the request's
/// `onLaunch`, which runs on the spawning thread: the tests check that thread and its QoS, and the child's own
/// scheduling priority.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ProcessLaunchPart3Tests {
    @MainActor
    @Test func theRuntimeTarListsAndUnpacksOffTheMainThread() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await Self.archive(["hello.txt": "hi"], in: root, gzip: false)
        let probe = SpawnProbe()
        let unpacker = TarChromiumRuntimeUnpacker(tool: URL(filePath: "/usr/bin/tar"), onLaunch: probe.onLaunch)
        let entries = try await unpacker.entries(of: archive)
        #expect(entries == ["hello.txt"])
        let out = root.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await unpacker.unpack(archive, into: out)
        #expect(try String(contentsOf: out.appending(path: "hello.txt"), encoding: .utf8) == "hi")
        #expect(probe.seen.count == 2, "one spawn per tar run")
        #expect(probe.seen.allSatisfy { !$0.onMain }, "a tar spawned on the main thread: \(probe.seen)")
    }

    /// tar's spawn runs at the caller's priority's QoS, and so does tar: a stand-in "tar" prints its own scheduling
    /// priority (`ps -o pri` of its shell), lower for a utility caller than for a high one.
    @Test func theRuntimeTarRunsAtItsCallersPriority() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appending(path: "report-priority")
        try Data("#!/bin/sh\n/bin/ps -o pri= -p $$\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let archive = root.appending(path: "unused.tar")

        let lowProbe = SpawnProbe(), highProbe = SpawnProbe()
        let lowTar = TarChromiumRuntimeUnpacker(tool: tool, onLaunch: lowProbe.onLaunch)
        let highTar = TarChromiumRuntimeUnpacker(tool: tool, onLaunch: highProbe.onLaunch)
        let low = try await Self.from(.utility) { try await lowTar.entries(of: archive) }
        let high = try await Self.from(.high) { try await highTar.entries(of: archive) }
        #expect(lowProbe.seen == [SpawnProbe.Spawn(onMain: false, qos: QOS_CLASS_UTILITY.rawValue)])
        #expect(highProbe.seen == [SpawnProbe.Spawn(onMain: false, qos: QOS_CLASS_USER_INITIATED.rawValue)])
        let lowPriority = try #require(low.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }, "\(low)")
        let highPriority = try #require(high.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }, "\(high)")
        #expect(lowPriority < highPriority, "tar of a utility caller runs at \(lowPriority), of a high caller at \(highPriority)")
    }

    @Test func theRuntimeTarReportsWhatTarSaidAndAMissingTool() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let garbage = root.appending(path: "garbage.tar")
        try Data("not an archive".utf8).write(to: garbage)
        let refused = await #expect(throws: ChromiumRuntimeInstallError.self) {
            _ = try await TarChromiumRuntimeUnpacker().entries(of: garbage)
        }
        if case .unpack(let message)? = refused {
            #expect(!message.isEmpty, "tar's message is the error")
        } else {
            Issue.record("a garbage archive failed with \(String(describing: refused))")
        }
        let missing = await #expect(throws: ChromiumRuntimeInstallError.self) {
            _ = try await TarChromiumRuntimeUnpacker(tool: URL(filePath: "/no/such/tar")).entries(of: garbage)
        }
        if case .unpack? = missing {} else { Issue.record("a missing tar failed with \(String(describing: missing))") }
    }

    /// A cancelled install never sees a cancel as an unpack failure: tar runs to its end and its listing returns.
    @Test func aCancelledListingStillReturnsTarsAnswer() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await Self.archive(["hello.txt": "hi"], in: root, gzip: false)
        let listing = Task { try await TarChromiumRuntimeUnpacker().entries(of: archive) }
        listing.cancel()
        let entries = try await listing.value
        #expect(entries == ["hello.txt"])
    }

    @MainActor
    @Test func aWebUpdateArchiveUnpacksOffTheMainThreadAndGarbageIsRefused() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await Self.archive(["index.html": "<p>web</p>"], in: root, gzip: true)
        let out = root.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let probe = SpawnProbe()
        try await WebUpdateStore.unpack(archive, into: out, onLaunch: probe.onLaunch)
        #expect(try String(contentsOf: out.appending(path: "index.html"), encoding: .utf8) == "<p>web</p>")
        #expect(probe.seen.count == 1)
        #expect(probe.seen.allSatisfy { !$0.onMain }, "tar spawned on the main thread: \(probe.seen)")

        let garbage = root.appending(path: "garbage.tgz")
        try Data("not an archive".utf8).write(to: garbage)
        await #expect(throws: WebUpdateRefusal.integrity("the archive did not unpack")) {
            try await WebUpdateStore.unpack(garbage, into: out)
        }
    }

    @MainActor
    @Test func theMailScriptRunnerSpawnsOffTheMainThreadAndReportsAFailedScript() async throws {
        let probe = SpawnProbe()
        let runner = OsascriptRunner(onLaunch: probe.onLaunch)
        let output = try await runner.run(["-e", "return \"hi\""])
        #expect(output == "hi\n")
        #expect(probe.seen.count == 1)
        #expect(probe.seen.allSatisfy { !$0.onMain }, "osascript spawned on the main thread: \(probe.seen)")
        do {
            _ = try await runner.run(["-e", "error \"boom\" number 7"])
            Issue.record("a failing script succeeded")
        } catch let failure as VerificationScriptFailure {
            #expect(failure.status != 0)
            #expect(failure.message.contains("boom"))
        }
    }

    @MainActor
    @Test func aServerHelperFixReturnsItsOutputAndALaunchFailure() async throws {
        let runner = ProcessFixRunner(limit: .seconds(20), tolerance: WakeLeeway.window(delay: .seconds(20)).tolerance)
        let result = try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo fixed; exit 2"])
        #expect(result == FixRunResult(status: 2, output: "fixed\n"))
        await #expect(throws: (any Error).self) {
            _ = try await runner.run(URL(fileURLWithPath: "/no/such/pmset"), [])
        }
    }

    /// The deadline's kill reaches the child: the shell writes its pid, then becomes `sleep 30`, and that pid is
    /// gone soon after the timeout.
    @Test func aServerHelperFixPastItsLimitIsKilled() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appending(path: "pid")
        let runner = ProcessFixRunner(limit: .seconds(1), tolerance: WakeLeeway.window(delay: .seconds(1)).tolerance)
        await #expect(throws: ServerHelperTimedOut()) {
            _ = try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo $$ > \"$0\"; exec /bin/sleep 30", pidFile.path])
        }
        let text = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), "the shell wrote \(text)")
        #expect(await Self.gone(pid), "the timed-out child \(pid) still runs")
    }

    /// A kill that comes before the spawn finished (the deadline fired while fork and exec still ran) kills the
    /// child as soon as it exists, so it never runs unbounded.
    @Test func aServerHelperFixKilledBeforeItsSpawnEndsAtTheSpawn() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let child = FixChild(URL(fileURLWithPath: "/bin/sleep"), ["30"])
        child.kill()
        let result = try await child.start()
        #expect(result.status == SIGKILL)
        #expect(started.duration(to: clock.now) < .seconds(15), "the stopped child ran on")
    }

    // MARK: Helpers

    /// The spawns of one wrapper, recorded by its `onLaunch` on the spawning thread.
    nonisolated final class SpawnProbe: Sendable {
        struct Spawn: Sendable, Equatable {
            var onMain: Bool
            /// The spawning thread's `qos_class_self()`.
            var qos: UInt32
        }

        private let spawns = Mutex<[Spawn]>([])

        var onLaunch: @Sendable (Int32) -> Void {
            { [self] _ in
                let spawn = Spawn(onMain: Thread.isMainThread, qos: qos_class_self().rawValue)
                spawns.withLock { $0.append(spawn) }
            }
        }

        var seen: [Spawn] {
            spawns.withLock { $0 }
        }
    }

    /// Runs `body` in a new task at `priority`. The wait is a continuation, never `Task.value`, which would raise
    /// the task to the test's own priority.
    static func from<T: Sendable>(_ priority: TaskPriority, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let result: Result<T, any Error> = await withCheckedContinuation { continuation in
            Task(priority: priority) {
                do {
                    continuation.resume(returning: .success(try await body()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        return try result.get()
    }

    /// True once `pid` no longer exists (Foundation reaps a killed child right after its exit), within 5 s.
    static func gone(_ pid: pid_t) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(5))
        while clock.now < end {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            try? await clock.sleep(for: .milliseconds(20))
        }
        return false
    }

    static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ProcessLaunchPart3-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A tar (gzip when `gzip`) of `files` (name to text), made in `root`.
    static func archive(_ files: [String: String], in root: URL, gzip: Bool) async throws -> URL {
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: source.appending(path: name)) }
        let archive = root.appending(path: gzip ? "pack.tgz" : "pack.tar")
        let made = try await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/tar"),
                                                               [gzip ? "-czf" : "-cf", archive.path, "-C", source.path] + files.keys.sorted(),
                                                               errorOutput: .merge))
        #expect(made.succeeded, "tar: \(made.text)")
        return archive
    }
}
