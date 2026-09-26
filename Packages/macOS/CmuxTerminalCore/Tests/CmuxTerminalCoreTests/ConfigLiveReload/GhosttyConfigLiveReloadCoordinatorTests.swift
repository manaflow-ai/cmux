import CmuxFoundation
import Testing
@testable import CmuxTerminalCore

/// Snapshot reader whose result the test replaces between file events.
private actor ScriptedSnapshotReader: GhosttyConfigLiveReloadSnapshotReading {
    private var current: GhosttyConfigLiveReloadSnapshot
    private(set) var readCount = 0

    init(_ initial: GhosttyConfigLiveReloadSnapshot) {
        current = initial
    }

    func set(_ snapshot: GhosttyConfigLiveReloadSnapshot) {
        current = snapshot
    }

    func snapshot() async -> GhosttyConfigLiveReloadSnapshot {
        readCount += 1
        return current
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

@MainActor
private final class ReloadCounter {
    var count = 0
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
        GhosttyConfigLiveReloadCoordinator(
            snapshotReader: reader,
            changeSource: source,
            debounce: .milliseconds(300),
            clock: clock
        ) {
            counter.count += 1
        }
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

        await reader.set(edited)
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
        await reader.set(edited)
        await source.emitChange()
        _ = await sleeps.next()
        await source.emitChange()
        _ = await sleeps.next()
        await clock.releaseAll()

        #expect(await outcomes.next() == .reloaded)
        #expect(await reader.readCount == 2)

        // The superseded debounce must not have queued a second evaluation:
        // the next outcome belongs to the next real edit.
        await reader.set(original)
        await source.emitChange()
        _ = await sleeps.next()
        await clock.releaseAll()

        #expect(await outcomes.next() == .reloaded)
        #expect(await reader.readCount == 3)
        #expect(counter.count == 2)
        coordinator.stop()
    }

    @Test func reloadCmuxStartedAbsorbsItsOwnFileWrite() async {
        let reader = ScriptedSnapshotReader(original)
        let source = ManualChangeSource()
        let counter = ReloadCounter()
        let coordinator = makeCoordinator(reader: reader, source: source, counter: counter)
        var outcomes = coordinator.outcomes.makeAsyncIterator()
        coordinator.start()
        #expect(await outcomes.next() == .baselineRecorded)

        // `cmux themes set` writes the config and reloads it itself.
        await reader.set(edited)
        coordinator.noteConfigurationDidReload()
        #expect(await outcomes.next() == .baselineRecorded)

        // The watcher's event for that write must not reload a second time.
        await source.emitChange()
        #expect(await outcomes.next() == .unchanged)
        #expect(counter.count == 0)
        coordinator.stop()
    }

    @Test func pendingUserEditSurvivesAnExternalReload() async {
        let reader = ScriptedSnapshotReader(original)
        let source = ManualChangeSource()
        let clock = GatedClock()
        let counter = ReloadCounter()
        let coordinator = makeCoordinator(reader: reader, source: source, clock: clock, counter: counter)
        var outcomes = coordinator.outcomes.makeAsyncIterator()
        var sleeps = clock.sleepStarted.makeAsyncIterator()
        coordinator.start()
        #expect(await outcomes.next() == .baselineRecorded)

        await reader.set(edited)
        await source.emitChange()
        _ = await sleeps.next()
        // An unrelated reload finishes while the edit is still debouncing; its
        // baseline refresh must not swallow the edit.
        coordinator.noteConfigurationDidReload()
        await clock.releaseAll()

        #expect(await outcomes.next() == .reloaded)
        #expect(counter.count == 1)
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

        await reader.set(.fixture(
            paths: ["/cfg/config", "/cfg/colors.conf"],
            contents: ["/cfg/config": "config-file = colors.conf\n", "/cfg/colors.conf": "background = #000\n"]
        ))
        await source.emitChange()
        #expect(await outcomes.next() == .reloaded)
        #expect(await source.subscribedPathSets == [["/cfg/config"], ["/cfg/config", "/cfg/colors.conf"]])
        #expect(await source.cancelledCount == 1)

        // Events from the re-armed subscription (the include) are delivered.
        await reader.set(.fixture(
            paths: ["/cfg/config", "/cfg/colors.conf"],
            contents: ["/cfg/config": "config-file = colors.conf\n", "/cfg/colors.conf": "background = #111\n"]
        ))
        await source.emitChange()
        #expect(await outcomes.next() == .reloaded)
        #expect(counter.count == 2)
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
