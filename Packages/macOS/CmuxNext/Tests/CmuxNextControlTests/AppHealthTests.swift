import CmuxNextCompat
import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeupsTestSupport
import Testing

/// App health's host (``AppHealth``) around the Rust model: one timer to the model's next deadline on
/// the injected clock, each action to its kind's repair, and the snapshot published only on change.
/// Needs the model linked (`CCmuxHealthFFI` in the pinned app FFI); without it every case is skipped.
@Suite(.timeLimit(.minutes(1)))
struct AppHealthTests {
    static let linked = AppHealth().isModelLinked

    /// Each repair the model asks for, in order; every repair "runs" (true).
    static func recording(_ health: AppHealth, _ kinds: [AppHealth.Kind]) -> AsyncStream<AppHealth.Action> {
        let (actions, record) = AsyncStream<AppHealth.Action>.makeStream()
        for kind in kinds {
            health.setRepair(kind) { action in
                record.yield(action)
                return true
            }
        }
        return actions
    }

    /// Returns once a published snapshot passes `check` (the current one counts).
    static func snapshot(of health: AppHealth, where check: @escaping @Sendable (JSONValue) -> Bool) async {
        let (passed, signal) = AsyncStream<Void>.makeStream()
        let token = health.subscribe { if check($0) { signal.yield() } }
        for await _ in passed { break }
        health.unsubscribe(token)
    }

    static func state(_ snapshot: JSONValue, _ id: String) -> String? {
        snapshot["parts"]?.arrayValue?.first { $0["id"]?.stringValue == id }?["state"]?.stringValue
    }

    @Test(.enabled(if: linked)) func aPageThatStopsBeatingIsReloadedThenItsRendererRestarted() async throws {
        let clock = ManualClock()
        let health = AppHealth(clock: clock)
        var repairs = Self.recording(health, [.page]).makeAsyncIterator()
        health.register("page:1", kind: .page, label: "Agent chat")
        health.beat("page:1")
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(10)) // slow at 5 s, stuck at 10 s
        let first = await repairs.next()
        #expect(first?.action == .reloadPage && first?.id == "page:1")
        await Self.snapshot(of: health) { Self.state($0, "page:1") == "repairing" }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(2)) // still silent after the first backoff
        let second = await repairs.next()
        #expect(second?.action == .restartRenderer)
    }

    @Test(.enabled(if: linked)) func aHiddenOrRemovedPageHasNoTimer() {
        let health = AppHealth(clock: ManualClock())
        #expect(!health.isTimerArmed, "nothing registered, nothing timed")
        health.register("page:1", kind: .page, label: "Agent chat")
        health.beat("page:1")
        #expect(health.isTimerArmed)
        health.visibility("page:1", visible: false)
        #expect(!health.isTimerArmed, "a hidden page is never timed")
        health.visibility("page:1", visible: true)
        #expect(health.isTimerArmed)
        health.unregister("page:1")
        #expect(!health.isTimerArmed)
    }

    @Test(.enabled(if: linked)) func anUnresponsiveRendererIsRestarted() async throws {
        let clock = ManualClock()
        let health = AppHealth(clock: clock)
        var repairs = Self.recording(health, [.renderer]).makeAsyncIterator()
        health.register("renderer:1", kind: .renderer, label: "Agent chat")
        health.event("renderer:1", .unresponsive)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        let action = await repairs.next()
        #expect(action?.action == .restartRenderer && action?.id == "renderer:1")
    }

    @Test(.enabled(if: linked)) func aSessionDaemonStartLoopHoldsReplaceUntilReady() async {
        let health = AppHealth(clock: ManualClock())
        let repaired = AppHealthTestBox(false)
        health.setRepair(.sessionDaemon) { _ in
            repaired.value = true
            return true
        }
        health.register(AppHealth.sessionDaemonID, kind: .sessionDaemon, label: "Session service")
        health.noteDaemonStarted()
        health.noteDaemonStarted()
        #expect(!health.holdsReplace)
        health.noteDaemonStarted() // three starts with no ready in 10 minutes: the next tick holds
        await Self.snapshot(of: health) { snapshot in
            snapshot["receipts"]?.arrayValue?.contains { $0["action"]?.stringValue == AppHealth.Repair.holdReplace.rawValue } == true
        }
        #expect(health.holdsReplace)
        #expect(!repaired.value, "holdReplace is a flag for the launcher, not a repair")
        health.noteDaemonReady(pid: 42)
        #expect(!health.holdsReplace)
    }

    @Test(.enabled(if: linked)) func aLostConnectionIsReconnected() async {
        let health = AppHealth(clock: ManualClock())
        var repairs = Self.recording(health, [.acpmux]).makeAsyncIterator()
        health.register(AppHealth.acpmuxID, kind: .acpmux, label: "Connection to the session service")
        health.event(AppHealth.acpmuxID, .disconnected)
        let action = await repairs.next()
        #expect(action?.action == .reconnect)
    }

    @Test(.enabled(if: linked)) func aMissingPageListenerRestartsThePageHost() async {
        let health = AppHealth(clock: ManualClock())
        var repairs = Self.recording(health, [.pageHost]).makeAsyncIterator()
        health.register(AppHealth.pageHostID, kind: .pageHost, label: "Page server")
        health.event(AppHealth.pageHostID, .listenerMissing)
        let action = await repairs.next()
        #expect(action?.action == .restartPageHost)
    }

    @Test(.enabled(if: linked)) func aRestoreThatMakesProgressHoldsReplacementsAtOnceAndAStalledOneDoesNot() {
        let clock = ManualClock()
        let health = AppHealth(clock: clock)
        #expect(!health.holdsReplace)
        // The first progress line holds: no start loop needs to be seen first.
        health.noteDaemonRestoring(pid: 42)
        #expect(health.holdsReplace)
        clock.advance(by: .seconds(119))
        #expect(health.holdsReplace)
        // No progress for the model's bound: stuck, no longer protected.
        clock.advance(by: .seconds(1))
        #expect(!health.holdsReplace)
        health.noteDaemonRestoring(pid: 42)
        health.noteDaemonReady(pid: 42)
        #expect(!health.holdsReplace, "a ready owner is no restore to protect")
    }

    /// Codex's review of #39247 (F2): the start-loop hold ended only on ready, so a daemon that loops
    /// and then stalls kept every automatic replacement held for the rest of the app's life.
    @Test(.enabled(if: linked)) func aStartLoopHoldEndsWhenTheDaemonStallsToo() async {
        let clock = ManualClock()
        let health = AppHealth(clock: clock)
        health.register(AppHealth.sessionDaemonID, kind: .sessionDaemon, label: "Session service")
        health.noteDaemonStarted()
        health.noteDaemonStarted()
        health.noteDaemonStarted()
        await Self.snapshot(of: health) { snapshot in
            snapshot["receipts"]?.arrayValue?.contains { $0["action"]?.stringValue == AppHealth.Repair.holdReplace.rawValue } == true
        }
        #expect(health.holdsReplace)
        clock.advance(by: .seconds(119))
        #expect(health.holdsReplace)
        clock.advance(by: .seconds(1))
        #expect(!health.holdsReplace, "a loop that makes no progress for the bound is stuck, not protected")
    }

    @Test(.enabled(if: linked)) func theSnapshotIsPublishedOnlyWhenItChanges() {
        let health = AppHealth(clock: ManualClock())
        let published = AppHealthTestBox(0)
        health.subscribe { _ in published.value += 1 }
        #expect(published.value == 1, "the current snapshot first")
        health.register("page:1", kind: .page, label: "Agent chat")
        health.beat("page:1")
        #expect(published.value == 1, "a healthy page is not in the snapshot")
        health.notePending(id: "close:1", label: "close Background task")
        #expect(published.value == 2)
        health.pendingDone(id: "close:1", ok: true)
        #expect(published.value == 3)
        #expect(Self.state(health.snapshot, "page:1") == nil)
    }
}

/// A value a `@Sendable` closure writes and the test reads.
final class AppHealthTestBox<Value: Sendable>: Sendable {
    private let state: Mutex<Value>
    init(_ value: Value) { state = Mutex(value) }
    var value: Value {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
