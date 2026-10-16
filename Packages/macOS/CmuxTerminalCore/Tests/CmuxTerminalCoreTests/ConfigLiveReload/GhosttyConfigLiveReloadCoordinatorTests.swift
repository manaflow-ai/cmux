import CmuxFoundation
import os
import Testing
@testable import CmuxTerminalCore

/// Snapshot reader whose result the test replaces between file events.
private final class ScriptedSnapshotReader: GhosttyConfigLiveReloadSnapshotReading, Sendable {
    private struct State {
        var current: GhosttyConfigLiveReloadSnapshot
        var upcoming: [GhosttyConfigLiveReloadSnapshot] = []
        var readCount = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ initial: GhosttyConfigLiveReloadSnapshot) {
        state = OSAllocatedUnfairLock(initialState: State(current: initial))
    }

    var readCount: Int {
        state.withLock { $0.readCount }
    }

    func set(_ snapshot: GhosttyConfigLiveReloadSnapshot) {
        state.withLock { $0.current = snapshot }
    }

    /// Makes the next reads return `snapshots` in order, then the last one.
    func setSequence(_ snapshots: [GhosttyConfigLiveReloadSnapshot]) {
        state.withLock { $0.upcoming = snapshots }
    }

    func snapshot() -> GhosttyConfigLiveReloadSnapshot {
        state.withLock { state in
            state.readCount += 1
            if !state.upcoming.isEmpty {
                state.current = state.upcoming.removeFirst()
            }
            return state.current
        }
    }
}

/// Change source whose events the test yields by hand.
private actor ManualChangeSource: GhosttyConfigChangeSource {
    private(set) var subscribedPathSets: [[String]] = []
    private(set) var cancelledCount = 0
    private var continuations: [AsyncStream<Void>.Continuation] = []

    func subscribe(toPaths paths: [String]) async -> GhosttyConfigChangeSubscription {
        subscribedPathSets.append(paths)
        let (events, continuation) = AsyncStream<Void>.makeStream()
        continuations.append(continuation)
        return GhosttyConfigChangeSubscription(events: events) {
            await self.recordCancel()
            continuation.finish()
        }
    }

    /// Simulates a filesystem event on the newest subscription.
    func emitChange() {
        continuations.last?.yield(())
    }

    private func recordCancel() {
        cancelledCount += 1
    }
}

/// Debounce clock that returns immediately.
private struct ImmediateClock: FileWatchClock {
    func sleep(for _: Duration) async throws {
        try Task.checkCancellation()
    }
}

/// Debounce clock that holds every sleeper until the test releases them.
private actor GatedClock: FileWatchClock {
    nonisolated let sleepStarted: AsyncStream<Void>
    private let sleepStartedContinuation: AsyncStream<Void>.Continuation
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        sleepStarted = stream
        sleepStartedContinuation = continuation
    }

    func sleep(for _: Duration) async throws {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            sleepStartedContinuation.yield(())
        }
    }

    func releaseAll() {
        let released = waiters
        waiters = []
        for waiter in released {
            waiter.resume()
        }
    }
}

/// Stands in for the app's reload: counts requests and, like
/// `GhosttyApp`, reports the config file read to the coordinator.
@MainActor
private final class ReloadCounter {
    var count = 0
    /// When `true`, each reload reads the files at once. When `false`, the
    /// test decides when the in-flight reload reads them.
    var loadsImmediately = true
    weak var coordinator: GhosttyConfigLiveReloadCoordinator?

    func reload() {
        count += 1
        if loadsImmediately {
            coordinator?.noteConfigurationFilesWillLoad()
        }
    }
}

private extension GhosttyConfigLiveReloadSnapshot {
    static func fixture(
        paths: [String] = ["/cfg/config", "/cfg/config.ghostty"],
        contents: [String: String]
    ) -> GhosttyConfigLiveReloadSnapshot {
        GhosttyConfigLiveReloadSnapshot(watchedPaths: paths, contentsByPath: contents)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct GhosttyConfigLiveReloadCoordinatorTests {
    private let original = GhosttyConfigLiveReloadSnapshot.fixture(contents: ["/cfg/config": "font-size = 13\n"])
    private let edited = GhosttyConfigLiveReloadSnapshot.fixture(contents: ["/cfg/config": "font-size = 15\n"])

    private func makeCoordinator(
        reader: ScriptedSnapshotReader,
        source: ManualChangeSource,
        clock: any FileWatchClock = ImmediateClock(),
        counter: ReloadCounter
    ) -> GhosttyConfigLiveReloadCoordinator {
        let coordinator = GhosttyConfigLiveReloadCoordinator(
            snapshotReader: reader,
            changeSource: source,
            debounce: .milliseconds(300),
            clock: clock
        ) {
            counter.reload()
        }
        counter.coordinator = coordinator
        return coordinator
    }

    @Test func startRecordsBaselineAndWatchesEveryResolvedPath() async {
        let reader = ScriptedSnapshotReader(original)
        let source = ManualChangeSource()
        let counter = ReloadCounter()
        let coordinator = makeCoordinator(reader: reader, source: source, counter: counter)
        var outcomes = coordinator.outcomes.makeAsyncIterator()

        coordinator.start()

        #expect(await outcomes.next() == .baselineRecorded)
        #expect(await source.subscribedPathSets == [["/cfg/config", "/cfg/config.ghostty"]])
        #expect(counter.count == 0)
        coordinator.stop()
    }

    @Test func contentChangeReloadsOnce() async {
        let reader = ScriptedSnapshotReader(original)
        let source = ManualChangeSource()
        let counter = ReloadCounter()
        let coordinator = makeCoordinator(reader: reader, source: source, counter: counter)
        var outcomes = coordinator.outcomes.makeAsyncIterator()
        coordinator.start()
        #expect(await outcomes.next() == .baselineRecorded)

        reader.set(edited)
        await source.emitChange()

        #expect(await outcomes.next() == .reloaded)
        #expect(counter.count == 1)
        coordinator.stop()
    }

    @Test func eventWithoutContentChangeDoesNotReload() async {
        let reader = ScriptedSnapshotReader(original)
        let source = ManualChangeSource()
        let counter = ReloadCounter()
        let coordinator = makeCoordinator(reader: reader, source: source, counter: counter)
        var outcomes = coordinator.outcomes.makeAsyncIterator()
        coordinator.start()
        #expect(await outcomes.next() == .baselineRecorded)

        // A directory event or an editor's swap file: nothing Ghostty reads changed.
        await source.emitChange()

        #expect(await outcomes.next() == .unchanged)
        #expect(counter.count == 0)
        coordinator.stop()
    }

    @Test func burstOfEventsIsDebouncedIntoOneEvaluation() async {
        let reader = ScriptedSnapshotReader(original)
        let source = ManualChangeSource()
        let clock = GatedClock()
        let counter = ReloadCounter()
        let coordinator = makeCoordinator(reader: reader, source: source, clock: clock, counter: counter)
        var outcomes = coordinator.outcomes.makeAsyncIterator()
        var sleeps = clock.sleepStarted.makeAsyncIterator()
        coordinator.start()
        #expect(await outcomes.next() == .baselineRecorded)

        // An atomic save: write temp file, rename over the config, touch dir.
        reader.set(edited)
        await source.emitChange()
        _ = await sleeps.next()
        await source.emitChange()
        _ = await sleeps.next()
        await clock.releaseAll()

        // Initial read, one evaluation, and the reload's own file read.
        #expect(await outcomes.next() == .reloaded)
        #expect(reader.readCount == 3)

        // The superseded debounce must not have queued a second evaluation:
        // the next outcome belongs to the next real edit.
        reader.set(original)
        await source.emitChange()
        _ = await sleeps.next()
        await clock.releaseAll()

        #expect(await outcomes.next() == .reloaded)
        #expect(reader.readCount == 5)
        #expect(counter.count == 2)
        coordinator.stop()
    }

    @Test func reloadCmuxStartedAbsorbsItsOwnFileWrite() async {
        let reader = ScriptedSnapshotReader(original)
        let source = ManualChangeSource()
        let clock = GatedClock()
        let counter = ReloadCounter()
        let coordinator = makeCoordinator(reader: reader, source: source, clock: clock, counter: counter)
        var outcomes = coordinator.outcomes.makeAsyncIterator()
        var sleeps = clock.sleepStarted.makeAsyncIterator()
        coordinator.start()
        #expect(await outcomes.next() == .baselineRecorded)

        // `cmux themes set` writes the config, then reloads it. The write's
        // event arrives first and is still debouncing when that reload reads
        // the files and finishes.
        reader.set(edited)
        await source.emitChange()
        _ = await sleeps.next()
        coordinator.noteConfigurationFilesWillLoad()
        coordinator.noteConfigurationDidReload()
        #expect(await outcomes.next() == .baselineRecorded)
        await clock.releaseAll()

        // The debounced evaluation sees nothing new: no second reload.
        #expect(await outcomes.next() == .unchanged)
        #expect(counter.count == 0)
        coordinator.stop()
    }

    /// The `cmux themes` preview writes the theme file and reloads it. When
    /// the preview's reload reads the files before the watcher evaluates, the
    /// write's own event must not reload a second time, even while that
    /// reload's fanout is still running.
    @Test func themePreviewWriteReloadsOnceWhileItsReloadIsStillApplying() async {
        let reader = ScriptedSnapshotReader(original)
        let source = ManualChangeSource()
        let clock = GatedClock()
        let counter = ReloadCounter()
        let coordinator = makeCoordinator(reader: reader, source: source, clock: clock, counter: counter)
        var outcomes = coordinator.outcomes.makeAsyncIterator()
        var sleeps = clock.sleepStarted.makeAsyncIterator()
        coordinator.start()
        #expect(await outcomes.next() == .baselineRecorded)

        reader.set(edited)
        await source.emitChange()
        _ = await sleeps.next()
        coordinator.noteConfigurationFilesWillLoad()
        await clock.releaseAll()

        #expect(await outcomes.next() == .unchanged)
        coordinator.noteConfigurationDidReload()
        #expect(await outcomes.next() == .baselineRecorded)
        #expect(counter.count == 0)
        coordinator.stop()
    }

    /// Saves during a reload the watcher started: one that lands after the
    /// in-flight reload read the files requests exactly one more reload, and
    /// one that lands before that read is covered by it.
    @Test func saveDuringAWatcherReloadRequestsExactlyOneMore() async {
        let reader = ScriptedSnapshotReader(original)
        let source = ManualChangeSource()
        let counter = ReloadCounter()
        counter.loadsImmediately = false
        let coordinator = makeCoordinator(reader: reader, source: source, counter: counter)
        var outcomes = coordinator.outcomes.makeAsyncIterator()
        coordinator.start()
        #expect(await outcomes.next() == .baselineRecorded)
        let edited2 = GhosttyConfigLiveReloadSnapshot.fixture(contents: ["/cfg/config": "font-size = 17\n"])

        reader.set(edited)
        await source.emitChange()
        #expect(await outcomes.next() == .reloaded)
        #expect(counter.count == 1)

        // The in-flight reload reads the files, then the user saves again.
        coordinator.noteConfigurationFilesWillLoad()
        reader.set(edited2)
        await source.emitChange()
        #expect(await outcomes.next() == .reloaded)
        #expect(counter.count == 2)

        // A save that lands before the queued reload reads the files is
        // covered by that read: its event does not request a third.
        reader.set(edited)
        coordinator.noteConfigurationFilesWillLoad()
        await source.emitChange()
        #expect(await outcomes.next() == .unchanged)
        coordinator.noteConfigurationDidReload()
        #expect(await outcomes.next() == .baselineRecorded)
        #expect(counter.count == 2)
        coordinator.stop()
    }

    /// A reload that finishes after a save it did not read must not swallow
    /// that save: the files it loaded are older than the edit.
    @Test func saveLandingWhileAReloadIsInFlightStillReloads() async {
        let reader = ScriptedSnapshotReader(original)
        let source = ManualChangeSource()
        let clock = GatedClock()
        let counter = ReloadCounter()
        let coordinator = makeCoordinator(reader: reader, source: source, clock: clock, counter: counter)
        var outcomes = coordinator.outcomes.makeAsyncIterator()
        var sleeps = clock.sleepStarted.makeAsyncIterator()
        coordinator.start()
        #expect(await outcomes.next() == .baselineRecorded)

        // A reload already read the original files; the user saves an edit
        // before that reload's fanout finishes.
        reader.set(edited)
        await source.emitChange()
        _ = await sleeps.next()
        coordinator.noteConfigurationDidReload()
        #expect(await outcomes.next() == .baselineRecorded)
        await clock.releaseAll()

        #expect(await outcomes.next() == .reloaded)
        #expect(counter.count == 1)
        coordinator.stop()
    }

    @Test func reloadNotificationBeforeTheWriteEventAlsoAbsorbsIt() async {
        let reader = ScriptedSnapshotReader(original)
        let source = ManualChangeSource()
        let counter = ReloadCounter()
        let coordinator = makeCoordinator(reader: reader, source: source, counter: counter)
        var outcomes = coordinator.outcomes.makeAsyncIterator()
        coordinator.start()
        #expect(await outcomes.next() == .baselineRecorded)

        reader.set(edited)
        coordinator.noteConfigurationFilesWillLoad()
        coordinator.noteConfigurationDidReload()
        #expect(await outcomes.next() == .baselineRecorded)
        await source.emitChange()

        #expect(await outcomes.next() == .unchanged)
        #expect(counter.count == 0)
        coordinator.stop()
    }

    @Test func rearmsWatchersWhenAnIncludeIsAdded() async {
        let reader = ScriptedSnapshotReader(.fixture(paths: ["/cfg/config"], contents: ["/cfg/config": ""]))
        let source = ManualChangeSource()
        let counter = ReloadCounter()
        let coordinator = makeCoordinator(reader: reader, source: source, counter: counter)
        var outcomes = coordinator.outcomes.makeAsyncIterator()
        coordinator.start()
        #expect(await outcomes.next() == .baselineRecorded)

        reader.set(.fixture(
            paths: ["/cfg/config", "/cfg/colors.conf"],
            contents: ["/cfg/config": "config-file = colors.conf\n", "/cfg/colors.conf": "background = #000\n"]
        ))
        await source.emitChange()
        #expect(await outcomes.next() == .reloaded)
        #expect(await source.subscribedPathSets == [["/cfg/config"], ["/cfg/config", "/cfg/colors.conf"]])
        #expect(await source.cancelledCount == 1)

        // Events from the re-armed subscription (the include) are delivered.
        reader.set(.fixture(
            paths: ["/cfg/config", "/cfg/colors.conf"],
            contents: ["/cfg/config": "config-file = colors.conf\n", "/cfg/colors.conf": "background = #111\n"]
        ))
        await source.emitChange()
        #expect(await outcomes.next() == .reloaded)
        #expect(counter.count == 2)
        coordinator.stop()
    }

    @Test func writeLandingWhileRearmingStillReloads() async {
        let reader = ScriptedSnapshotReader(.fixture(paths: ["/cfg/config"], contents: ["/cfg/config": ""]))
        let source = ManualChangeSource()
        let counter = ReloadCounter()
        let coordinator = makeCoordinator(reader: reader, source: source, counter: counter)
        var outcomes = coordinator.outcomes.makeAsyncIterator()
        coordinator.start()
        #expect(await outcomes.next() == .baselineRecorded)

        // The evaluation and the reload it starts both read an added include
        // that does not exist yet; the include is written before its watcher
        // attaches, so only the re-read after re-arming can see it.
        let includeAdded = GhosttyConfigLiveReloadSnapshot.fixture(
            paths: ["/cfg/config", "/cfg/colors.conf"],
            contents: ["/cfg/config": "config-file = colors.conf\n"]
        )
        reader.setSequence([
            includeAdded,
            includeAdded,
            .fixture(
                paths: ["/cfg/config", "/cfg/colors.conf"],
                contents: ["/cfg/config": "config-file = colors.conf\n", "/cfg/colors.conf": "background = #000\n"]
            ),
        ])
        await source.emitChange()

        #expect(await outcomes.next() == .reloaded)
        #expect(counter.count == 2)
        #expect(reader.readCount == 5)
        coordinator.stop()
    }

    @Test func stopFinishesOutcomes() async {
        let reader = ScriptedSnapshotReader(original)
        let source = ManualChangeSource()
        let coordinator = makeCoordinator(reader: reader, source: source, counter: ReloadCounter())
        var outcomes = coordinator.outcomes.makeAsyncIterator()
        coordinator.start()
        #expect(await outcomes.next() == .baselineRecorded)

        coordinator.stop()

        #expect(await outcomes.next() == nil)
    }
}
