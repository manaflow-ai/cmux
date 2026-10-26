#if DEBUG || CMUX_PGO_PROFILE
import CmuxNextCompat
import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The profile build's two profiles from one run (p08-startup-103): launch.profraw at startup complete
/// (written, then the counters reset), rest.profraw at `debug.pgo_flush`, both non-empty, on a fake
/// runtime that writes its counter to the file it was last given.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ProfileFlushTests {
    @Test func aRunWritesTheLaunchThenTheRestProfile() async throws {
        let f = FlushFixture()
        f.runtime.count(3)
        let launch = try await f.flush.writeLaunchProfile()
        f.runtime.count(5)
        let rest = try await f.flush.writeRestProfile()
        #expect(launch.profile == .launch && launch.file == f.files.launch)
        #expect(rest.profile == .rest && rest.file == f.files.rest)
        #expect(launch.bytes > 0 && rest.bytes > 0, "two non-empty profiles per launch")
        #expect(try f.contents(f.files.launch) == "counters 3", "the launch profile holds the launch only")
        #expect(try f.contents(f.files.rest) == "counters 5", "the counters were reset after the launch write")
        #expect(f.runtime.calls == ["set launch.profraw", "write", "reset", "set rest.profraw", "write"],
                "the rest file is the runtime's file after the launch, so its write at exit lands there too")
    }

    @Test func theRestProfileBeforeStartupCompleteIsRefused() async throws {
        let f = FlushFixture()
        await #expect(throws: ProfileFlush.Failure.launchNotWritten) { try await f.flush.writeRestProfile() }
        #expect(f.runtime.calls.isEmpty, "no write: its counters would hold the launch")
    }

    @Test func startupCompleteWritesTheLaunchProfile() async throws {
        let f = FlushFixture()
        f.flush.writeLaunchProfile(when: f.scheduler.startup)
        f.runtime.count(2)
        #expect(f.scheduler.startup.completion == nil)
        #expect(f.runtime.calls.isEmpty, "nothing before completion")
        f.scheduler.complete()
        // One serial lane slot: the rest write runs after the launch write that completion posted.
        let rest = try await f.flush.writeRestProfile()
        #expect(try f.contents(f.files.launch) == "counters 2")
        #expect(rest.file == f.files.rest)
    }

    @Test func aQuitBeforeCompletionWritesNoLaunchProfile() async throws {
        let f = FlushFixture()
        f.flush.writeLaunchProfile(when: f.scheduler.startup)
        f.scheduler.startup.beginQuit()
        f.scheduler.complete()
        await #expect(throws: ProfileFlush.Failure.launchNotWritten) { try await f.flush.writeRestProfile() }
        #expect(!FileManager.default.fileExists(atPath: f.files.launch.path))
    }

    @Test func aFailedLaunchWriteKeepsTheCountersAndRefusesTheRest() async throws {
        let f = FlushFixture()
        f.runtime.failWrites(-1)
        await #expect(throws: ProfileFlush.Failure.writeFailed(.launch, code: -1)) { try await f.flush.writeLaunchProfile() }
        #expect(f.runtime.calls == ["set launch.profraw", "write"], "no reset after a failed write")
        await #expect(throws: ProfileFlush.Failure.launchNotWritten) { try await f.flush.writeRestProfile() }
    }

    @Test func anEmptyProfileIsAFailure() async throws {
        let f = FlushFixture()
        f.runtime.writesNothing()
        await #expect(throws: ProfileFlush.Failure.empty(.launch)) { try await f.flush.writeLaunchProfile() }
    }

    @Test func theFilesGoBesideTheRuntimesFile() {
        let temporary = URL(fileURLWithPath: "/private/tmp/t", isDirectory: true)
        let runner = ProfileFlush.Files(environment: ["LLVM_PROFILE_FILE": "/work/run-1/default.profraw"], temporaryFolder: temporary)
        #expect(runner.launch.path == "/work/run-1/launch.profraw")
        #expect(runner.rest.path == "/work/run-1/rest.profraw")
        let unset = ProfileFlush.Files(environment: ["LLVM_PROFILE_FILE": ""], temporaryFolder: temporary)
        #expect(unset.launch.path == "/private/tmp/t/cmux-pgo/launch.profraw")
    }
}

/// A flush on the shared startup test scheduler's lanes, writing to a fresh folder.
@MainActor
private final class FlushFixture {
    let scheduler = StartupTestScheduler()
    let runtime = FakeProfileRuntime()
    let files: ProfileFlush.Files
    let flush: ProfileFlush

    init() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "profile-flush-\(UUID().uuidString)", directoryHint: .isDirectory)
        files = ProfileFlush.Files(folder: folder)
        flush = ProfileFlush(runtime: runtime.runtime, files: files, work: scheduler.background)
    }

    func contents(_ file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }
}

/// The compiler-rt runtime's three calls on one counter: a write puts `counters <n>` in the file last set.
private nonisolated final class FakeProfileRuntime: Sendable {
    private struct State {
        var file: String?
        var counter = 0
        var calls: [String] = []
        var writeCode: Int32 = 0
        var writesBytes = true
    }

    private let state = Mutex(State())

    var calls: [String] { state.withLock { $0.calls } }

    func count(_ hits: Int) { state.withLock { $0.counter += hits } }
    func failWrites(_ code: Int32) { state.withLock { $0.writeCode = code } }
    func writesNothing() { state.withLock { $0.writesBytes = false } }

    var runtime: ProfileFlush.Runtime {
        ProfileFlush.Runtime(
            setFile: { [self] name in
                state.withLock { $0.file = name; $0.calls.append("set \(URL(fileURLWithPath: name).lastPathComponent)") }
            },
            write: { [self] in
                let (file, text, code): (String?, String, Int32) = state.withLock { s in
                    s.calls.append("write")
                    return (s.file, s.writesBytes ? "counters \(s.counter)" : "", s.writeCode)
                }
                guard code == 0, let file else { return code == 0 ? -1 : code }
                return FileManager.default.createFile(atPath: file, contents: Data(text.utf8)) ? 0 : -1
            },
            resetCounters: { [self] in state.withLock { $0.counter = 0; $0.calls.append("reset") } })
    }
}
#endif
