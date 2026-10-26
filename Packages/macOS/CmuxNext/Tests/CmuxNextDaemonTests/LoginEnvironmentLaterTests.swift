import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The login shell's environment is captured after startup (p08-startup-034): with a remembered
/// copy, neither starting the daemon nor a new terminal runs `$SHELL -l -i` before the launch's
/// afterStartup post does; a cold daemon with nothing remembered still starts it at once.
@Suite(.timeLimit(.minutes(1)))
struct LoginEnvironmentLaterTests {
    @Test func aRememberedEnvironmentRunsNoShellUntilTheAfterStartupStart() async {
        let shell = FakeLoginShell(path: "/captured/bin")
        let cache = LoginEnvironmentCache(store: .remembering(path: "/remembered/bin"), capture: shell.capture)
        #expect(await cache.immediate()?["PATH"] == "/remembered/bin")
        #expect(await cache.value()?["PATH"] == "/remembered/bin")
        #expect(shell.runs == 0, "a shell ran before startup completed although an environment was remembered")
        await cache.start()
        await shell.waitForRun()
        #expect(shell.runs == 1)
    }

    @Test func aColdDaemonWithNothingRememberedStartsTheCaptureAtOnce() async {
        let shell = FakeLoginShell(path: "/captured/bin")
        let cache = LoginEnvironmentCache(store: .remembering(path: nil), capture: shell.capture)
        #expect(await cache.immediate() == nil, "starting the daemon never waits for the login shell")
        await shell.waitForRun()
        #expect(await cache.value()?["PATH"] == "/captured/bin")
        await cache.start()
        #expect(shell.runs == 1, "the after-startup start keeps the capture already running")
    }

    @Test func aTerminalWithNothingRememberedWaitsForTheCapture() async {
        let shell = FakeLoginShell(path: "/captured/bin")
        let cache = LoginEnvironmentCache(store: .remembering(path: nil), capture: shell.capture)
        #expect(await cache.value()?["PATH"] == "/captured/bin")
        #expect(shell.runs == 1)
    }

    @MainActor
    @Test func theCaptureIsAnAfterStartupPostOnTheSystemLaneAtBestEffort() async {
        let s = StartupTestScheduler()
        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        DaemonLauncher.postLoginEnvironmentCapture(on: s.startup) { signal.yield() }
        let restore = s.startup.hold("WindowManager.restore")
        s.complete()
        for _ in 0..<4 { s.fire() }
        let held = s.startup.log.records
        #expect(held.map(\.name.description) == ["LoginEnvironment.capture"])
        #expect(held.allSatisfy { $0.priority == .afterStartup && $0.destination == .lane(.system, .bestEffort) && $0.violation == nil })
        #expect(held.allSatisfy { $0.durationNanos == nil }, "the capture started before startup completed")
        restore.release(.visiblePaneLoadedIdle)
        s.hand.drain()
        for await _ in started { break }
        #expect(s.startup.completion?.heldTasks == 1)
    }
}

/// A login shell that records each run and answers with `path`.
private final class FakeLoginShell: Sendable {
    private let state = Mutex<Int>(0)
    private let ran: AsyncStream<Void>
    private let ranSignal: AsyncStream<Void>.Continuation
    private let path: String

    init(path: String) {
        self.path = path
        (ran, ranSignal) = AsyncStream.makeStream(of: Void.self)
    }

    var runs: Int { state.withLock { $0 } }

    var capture: @Sendable (Duration) async -> [String: String]? {
        { [self] _ in
            state.withLock { $0 += 1 }
            ranSignal.yield()
            return ["PATH": path, "HOME": "/Users/test"]
        }
    }

    /// Returns once the shell has run (at once when it already has).
    func waitForRun() async {
        for await _ in ran { break }
    }
}

private extension LoginEnvironmentStore {
    /// A store whose file holds `path` (nil: nothing remembered) and drops every save.
    static func remembering(path: String?) -> LoginEnvironmentStore {
        let data = path.flatMap { path in
            try? JSONEncoder().encode(Record(version: version, environment: ["PATH": path, "HOME": "/Users/test"]))
        }
        return LoginEnvironmentStore(read: { data }, write: { _ in })
    }
}
