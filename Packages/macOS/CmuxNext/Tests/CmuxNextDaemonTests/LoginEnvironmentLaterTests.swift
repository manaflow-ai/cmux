import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The login shell's environment is captured after startup: with a remembered
/// copy, neither starting the daemon nor a new terminal runs `$SHELL -l -i` before startup
/// completes; with nothing remembered the capture starts at once, warm daemon or cold.
///
/// `captureStarted` is read on the cache's actor right after the call under test, so a capture
/// task made by that call is always seen (the base's `immediate()` made one).
@Suite(.timeLimit(.minutes(1)))
struct LoginEnvironmentLaterTests {
    @Test func aRememberedEnvironmentStartsNoCaptureUntilStart() async {
        let shell = FakeLoginShell(path: "/captured/bin")
        let cache = LoginEnvironmentCache(store: .remembering(path: "/remembered/bin"), capture: shell.capture)
        await cache.startIfNothingRemembered()
        #expect(await cache.immediate()?["PATH"] == "/remembered/bin")
        #expect(await cache.value()?["PATH"] == "/remembered/bin")
        let early = await cache.captureStarted
        #expect(!early, "a capture started before startup completed although an environment was remembered")
        await cache.start()
        let started = await cache.captureStarted
        #expect(started)
        await shell.waitForRun()
        #expect(shell.runs == 1)
    }

    @Test func aColdDaemonWithNothingRememberedStartsTheCaptureAtOnce() async {
        let shell = FakeLoginShell(path: "/captured/bin")
        let cache = LoginEnvironmentCache(store: .remembering(path: nil), capture: shell.capture)
        #expect(await cache.immediate() == nil, "starting the daemon never waits for the login shell")
        let started = await cache.captureStarted
        #expect(started)
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

    /// A warm daemon runs no `server ensure`, so no `immediate()` call starts the capture: the
    /// launch's own start must, before startup completes.
    @MainActor
    @Test func aWarmDaemonWithNothingRememberedStartsTheCaptureBeforeStartupCompletes() async {
        let s = StartupTestScheduler()
        let shell = FakeLoginShell(path: "/captured/bin")
        let cache = LoginEnvironmentCache(store: .remembering(path: nil), capture: shell.capture)
        let restore = s.startup.hold("WindowManager.restore")
        DaemonLauncher.captureLoginEnvironment(cache, after: s.startup)
        s.complete()
        await shell.waitForRun()
        #expect(s.startup.completion == nil, "the capture waited for startup to complete")
        restore.release(.visiblePaneLoadedIdle)
        s.hand.drain()
        #expect(await cache.value()?["PATH"] == "/captured/bin")
    }

    /// With a remembered copy the capture starts from the scheduler's completion, and not before.
    @MainActor
    @Test func aRememberedEnvironmentIsRefreshedOnceStartupCompletes() async {
        let s = StartupTestScheduler()
        let shell = FakeLoginShell(path: "/captured/bin")
        let cache = LoginEnvironmentCache(store: .remembering(path: "/remembered/bin"), capture: shell.capture)
        let restore = s.startup.hold("WindowManager.restore")
        DaemonLauncher.captureLoginEnvironment(cache, after: s.startup)
        s.complete()
        for _ in 0..<4 { s.fire() }
        // The launch's store check is the one call that may run here; it finds the remembered copy.
        await cache.startIfNothingRemembered()
        let early = await cache.captureStarted
        #expect(!early, "a capture started before startup completed although an environment was remembered")
        restore.release(.visiblePaneLoadedIdle)
        s.hand.drain()
        #expect(s.startup.completion != nil)
        await shell.waitForRun()
        #expect(shell.runs == 1)
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

    /// Returns once the shell has run (at once when it already has). Call it once per test.
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
