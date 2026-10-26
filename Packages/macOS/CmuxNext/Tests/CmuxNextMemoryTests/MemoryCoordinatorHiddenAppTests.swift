import CmuxNextCompat
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import CmuxNextMemory
import CmuxNextWakeups
import Dispatch
import Testing

/// While no cmux window is visible, ``MemoryCoordinator`` releases in 8 ms slices back to back on
/// main-queue turns instead of 2 ms slices on frames that a hidden app gets only on the frame
/// scheduler's 100 ms stall deadline; input or a shown window puts the next slice back on a frame,
/// and a frame slice with no input since the one before it lets a hidden app go back to turns.
///
/// Time is a ``ManualClock``: consumer work advances it, ``drive(frameGap:)`` adds the gap before
/// each frame (a stall tick when hidden, a refresh when visible) and a little queued work before
/// each turn.
@MainActor @Suite struct MemoryCoordinatorHiddenAppTests {
    /// The hidden app's frame gap: `FrameScheduler.stallTimeout`.
    static let stallFrameGap: Duration = .milliseconds(100)
    static let visibleFrameGap: Duration = .microseconds(16_667)
    /// Other work the main queue runs between two release turns.
    static let turnGap: Duration = .microseconds(100)

    let clock = ManualClock()
    let log = CallLog()
    let source = ManualMemoryPressureSource(initial: .normal)
    let pressure: MemoryPressureEvents
    let slicer: ManualSlicer
    let turns: ManualTurns
    let coordinator: MemoryCoordinator

    init() {
        self.init(withTurns: true)
    }

    init(withTurns: Bool) {
        pressure = MemoryPressureEvents(source: source)
        slicer = ManualSlicer(clock: clock)
        turns = ManualTurns(clock: clock)
        coordinator = MemoryCoordinator(
            pressure: pressure, slicer: slicer, turns: withTurns ? turns as any MemoryReleaseTurns : nil, clock: clock)
    }

    func consumer(_ name: String, entries: Int, costPerEntry: Duration = .milliseconds(1)) -> RecordingConsumer {
        RecordingConsumer(name: name, entries: entries, costPerEntry: costPerEntry, clock: clock, log: log)
    }

    func register(_ consumer: RecordingConsumer) -> MemoryConsumerRegistration {
        MemoryConsumerRegistration(name: consumer.name, traits: managedTraits(), consumer: consumer, registry: coordinator)
    }

    /// Runs turns and frames as the main queue would until neither is asked for: a turn first when
    /// one is waiting, else the next frame after `frameGap`. Returns the clock time it took.
    @discardableResult
    func drive(frameGap: Duration, limit: Int = 10_000) -> Duration {
        let start = clock.now
        for _ in 0..<limit {
            if turns.hasPendingTurn {
                clock.advance(by: Self.turnGap)
                turns.runTurn()
            } else if slicer.hasPendingSlice {
                clock.advance(by: frameGap)
                slicer.fireFrame()
            } else {
                break
            }
        }
        return start.duration(to: clock.now)
    }

    @Test func aHiddenAppReleasesA500EntryConsumerInUnderASecond() {
        let big = consumer("big", entries: 500)
        let registration = register(big)
        coordinator.isAppHidden = true
        source.send(.critical)
        let elapsed = drive(frameGap: Self.stallFrameGap)
        #expect(big.entries == 0, "the hidden release left \(big.entries) entries")
        #expect(elapsed < .seconds(1), "500 ms of release work took \(elapsed) hidden")
        #expect(slicer.requests == 0, "a hidden release waited for a frame")
        #expect(turns.turnDurations.allSatisfy { $0 <= MemoryCoordinator.hiddenSliceBudget },
                "a hidden turn ran over \(MemoryCoordinator.hiddenSliceBudget): \(turns.turnDurations.max() ?? .zero)")
        #expect(turns.turnDurations.contains { $0 > MemoryCoordinator.sliceBudget }, "hidden turns kept the 2 ms slice")
        withExtendedLifetime(registration) {}
    }

    @Test func withoutTurnsAHiddenAppReleasesOnlyOnStallFrames() {
        let frameOnly = MemoryCoordinatorHiddenAppTests(withTurns: false)
        let big = frameOnly.consumer("big", entries: 500)
        let registration = frameOnly.register(big)
        frameOnly.coordinator.isAppHidden = true
        #expect(frameOnly.coordinator.pace == .frames)
        frameOnly.source.send(.critical)
        let elapsed = frameOnly.drive(frameGap: Self.stallFrameGap)
        #expect(big.entries == 0)
        // 250 frames of 2 ms, one per stall: the time the hidden pace exists to avoid.
        #expect(elapsed > .seconds(20), "frames alone took \(elapsed)")
        #expect(frameOnly.slicer.frameDurations.allSatisfy { $0 <= MemoryCoordinator.sliceBudget })
        withExtendedLifetime(registration) {}
    }

    @Test func aVisibleAppKeepsTwoMillisecondFrameSlices() {
        let big = consumer("big", entries: 500)
        let registration = register(big)
        source.send(.critical)
        drive(frameGap: Self.visibleFrameGap)
        #expect(big.entries == 0)
        #expect(turns.requests == 0, "a visible app released on main-queue turns")
        #expect(slicer.frameDurations.allSatisfy { $0 <= MemoryCoordinator.sliceBudget },
                "a frame slice ran over \(MemoryCoordinator.sliceBudget): \(slicer.frameDurations.max() ?? .zero)")
        withExtendedLifetime(registration) {}
    }

    @Test func theFirstHiddenSliceIsNotInTheEventTurn() {
        let big = consumer("big", entries: 500)
        let registration = register(big)
        coordinator.isAppHidden = true
        log.clear()
        source.send(.critical)
        #expect(log.calls == [.limit("big", 0)], "the event turn did more than set the limit")
        #expect(turns.hasPendingTurn && !slicer.hasPendingSlice)
        withExtendedLifetime(registration) {}
    }

    @Test func inputPutsTheNextSliceBackOnAFrameAtOnce() {
        let big = consumer("big", entries: 500)
        let registration = register(big)
        coordinator.isAppHidden = true
        source.send(.critical)
        turns.runTurn()
        #expect(turns.hasPendingTurn, "the test needs a hidden release in progress")

        coordinator.inputDidArrive()
        #expect(coordinator.pace == .frames)
        #expect(slicer.hasPendingSlice, "input did not ask for a frame")
        let left = big.entries
        let releases = log.releases.count
        turns.runTurn()
        #expect(big.entries == left && log.releases.count == releases, "the turn asked before the input still released")

        // Input before every frame keeps every slice on a frame at 2 ms.
        for _ in 0..<5 {
            coordinator.inputDidArrive()
            clock.advance(by: Self.stallFrameGap)
            #expect(slicer.fireFrame(), "the release stopped asking for frames while input came")
            #expect(coordinator.pace == .frames, "a slice went back to turns while input kept coming")
        }
        #expect(big.entries > 0, "the test needs the release still in progress")
        #expect(slicer.frameDurations.allSatisfy { $0 <= MemoryCoordinator.sliceBudget })
        withExtendedLifetime(registration) {}
    }

    @Test func afterAFrameWithNoInputAHiddenReleaseGoesBackToTurns() {
        let big = consumer("big", entries: 500)
        let registration = register(big)
        coordinator.isAppHidden = true
        source.send(.critical)
        turns.runTurn()
        let inputAt = clock.now
        coordinator.inputDidArrive()

        clock.advance(by: Self.stallFrameGap)
        slicer.fireFrame()
        #expect(coordinator.pace == .frames, "the frame slice the input asked for already went back to turns")
        clock.advance(by: Self.stallFrameGap)
        slicer.fireFrame()
        #expect(coordinator.pace == .hiddenTurns, "a frame slice with no input since the last one kept the 2 ms rule")
        #expect(turns.hasPendingTurn, "no turn waits after the pace went back to turns")
        let framesBeforeTurns = slicer.frameDurations.count

        drive(frameGap: Self.stallFrameGap)
        #expect(big.entries == 0, "the release left \(big.entries) entries")
        let elapsed = inputAt.duration(to: clock.now)
        #expect(elapsed < .seconds(1), "one input held the rest of a hidden release on stall frames: \(elapsed)")
        // Only the stale frame the second slice asked for may come after; it releases nothing.
        #expect(slicer.frameDurations.dropFirst(framesBeforeTurns).allSatisfy { $0 == .zero },
                "a frame slice ran after the pace went back to turns")
        #expect(turns.turnDurations.contains { $0 > MemoryCoordinator.sliceBudget }, "the turns kept the 2 ms slice")
        withExtendedLifetime(registration) {}
    }

    @Test func followAppHidesWithTheWindowsAndHearsTheTapsInput() {
        let windows = ShownWindows()
        let window = VisibilityNode(root: "window", own: .visible)
        windows.track(window)
        let tap = FakeInputTap()
        coordinator.followApp(windows: windows, input: tap)
        #expect(!coordinator.isAppHidden)

        window.set(.hidden)
        #expect(coordinator.isAppHidden && coordinator.pace == .hiddenTurns)
        tap.deliver(InputEventRecord(type: .mouseMoved, timestamp: 1))
        #expect(coordinator.pace == .hiddenTurns, "a pointer move counted as input")
        tap.deliver(InputEventRecord(type: .keyDown, timestamp: 2))
        #expect(coordinator.pace == .frames, "a key from the tap did not count as input")

        window.set(.visible)
        #expect(!coordinator.isAppHidden)
        #expect(tap.liveSubscriptions == 1)
    }

    @Test func followAppStartsFromTheWindowsShownNow() {
        coordinator.followApp(windows: ShownWindows(), input: FakeInputTap())
        #expect(!coordinator.isAppHidden, "a launch with no window yet counted as hidden")

        let windows = ShownWindows()
        let window = VisibilityNode(root: "window", own: .hidden)
        windows.track(window)
        let hidden = MemoryCoordinatorHiddenAppTests()
        hidden.coordinator.followApp(windows: windows, input: FakeInputTap())
        #expect(hidden.coordinator.isAppHidden, "an app whose only window is hidden counted as shown")
        withExtendedLifetime(window) {}
    }

    @Test func aWindowThatShowsPutsTheNextSliceBackOnAFrame() {
        let big = consumer("big", entries: 500)
        let registration = register(big)
        coordinator.isAppHidden = true
        source.send(.critical)
        turns.runTurn()

        coordinator.isAppHidden = false
        #expect(coordinator.pace == .frames && slicer.hasPendingSlice)
        let left = big.entries
        turns.runTurn()
        #expect(big.entries == left, "a turn ran after a window showed")
        slicer.fireFrame()
        #expect(slicer.frameDurations.allSatisfy { $0 <= MemoryCoordinator.sliceBudget })
        withExtendedLifetime(registration) {}
    }

    @Test func hidingMidReleaseMovesTheReleaseToTurns() {
        let big = consumer("big", entries: 500)
        let registration = register(big)
        source.send(.critical)
        slicer.fireFrame()
        #expect(slicer.hasPendingSlice, "the test needs a visible release in progress")

        coordinator.isAppHidden = true
        #expect(coordinator.pace == .hiddenTurns && turns.hasPendingTurn)
        let left = big.entries
        slicer.fireFrame()
        #expect(big.entries == left, "a frame slice ran after the app was hidden")
        let elapsed = drive(frameGap: Self.stallFrameGap)
        #expect(big.entries == 0)
        #expect(elapsed < .seconds(1))
        // The first frame and the one its unfinished slice asked for; none once hidden.
        #expect(!slicer.hasPendingSlice && slicer.requests == 2, "the hidden release asked for frames")
        withExtendedLifetime(registration) {}
    }

    @Test func aHiddenCriticalPassRelievesTheHeapOnceWhenItsLastTurnEnds() async {
        let reliefs = ReleaseThreadLog()
        let sink = MemoryReleaseSink(
            queue: DispatchQueue(label: "test.hidden-app.release-sink"),
            heapRelief: .init { reliefs.record() })
        let hidden = MemoryCoordinator(
            pressure: pressure, slicer: slicer, turns: turns, clock: clock, releaseSink: sink)
        let big = consumer("big", entries: 40)
        let registration = MemoryConsumerRegistration(
            name: big.name, traits: managedTraits(), consumer: big, registry: hidden)
        hidden.isAppHidden = true
        source.send(.critical)
        turns.runTurn()
        await sink.drained()
        #expect(big.entries > 0, "the test needs a pass longer than one turn")
        #expect(reliefs.count == 0, "the heap was relieved before the hidden pass finished")
        drive(frameGap: Self.stallFrameGap)
        await sink.drained()
        #expect(big.entries == 0)
        #expect(reliefs.count == 1)
        withExtendedLifetime((registration, hidden)) {}
    }

    @Test func hidingAgainAfterInputReturnsToTurns() {
        coordinator.isAppHidden = true
        coordinator.inputDidArrive()
        #expect(coordinator.pace == .frames)
        coordinator.isAppHidden = false
        coordinator.isAppHidden = true
        #expect(coordinator.pace == .hiddenTurns)
    }

    @Test func nothingToReleaseAsksForNothing() {
        let big = consumer("big", entries: 500)
        let registration = register(big)
        coordinator.isAppHidden = true
        coordinator.inputDidArrive()
        coordinator.isAppHidden = false
        coordinator.inputDidArrive()
        #expect(turns.requests == 0 && slicer.requests == 0, "a pace change with no release asked for a slice")
        withExtendedLifetime(registration) {}
    }
}

/// A ``MemoryReleaseTurns`` whose main-queue turns the test runs: ``runTurn()`` runs the turn asked
/// for and records the clock time it took.
@MainActor
final class ManualTurns: MemoryReleaseTurns {
    private var pending: [@MainActor () -> Void] = []
    private let clock: ManualClock
    /// How many turns were asked for since the start.
    private(set) var requests = 0
    /// The clock time each run turn took.
    private(set) var turnDurations: [Duration] = []

    init(clock: ManualClock) {
        self.clock = clock
    }

    var hasPendingTurn: Bool { !pending.isEmpty }

    func scheduleTurn(_ turn: @escaping @MainActor () -> Void) {
        requests += 1
        pending.append(turn)
    }

    /// Runs the oldest turn asked for, if any.
    func runTurn() {
        guard !pending.isEmpty else { return }
        let turn = pending.removeFirst()
        let start = clock.now
        turn()
        turnDurations.append(start.duration(to: clock.now))
    }
}
