@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextErrorJournal
import CmuxNextFiles
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// p14-energy-066a: the error journal harvests once at start, then on the system's background activity
/// scheduler (fired by hand here), and a run reads the sources only when a watched log folder changed.
/// Folder changes are sent by hand; finishing the streams ends the watch tasks, so awaiting them proves
/// that every change was seen before the next run.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ErrorJournalServiceTests {
    nonisolated static let chief = URL(fileURLWithPath: "/tmp/error-journal-tests/chief", isDirectory: true)
    nonisolated static let reports = URL(fileURLWithPath: "/tmp/error-journal-tests/DiagnosticReports", isDirectory: true)
    nonisolated static let watched = ErrorJournalService.folderWatches(
        logs: [chief.appendingPathComponent("host.log"), chief.appendingPathComponent("client.log")], reports: reports)

    // MARK: Cadence

    @Test func itHarvestsAtStartThenOnTheSystemActivity() async throws {
        let rig = Rig()
        defer { rig.removeJournal() }

        rig.service.start()
        await rig.service.launchHarvest?.value
        #expect(rig.source.harvests == 1, "start did not harvest at once")
        #expect(rig.activities.live == [BackgroundActivity(identifier: "test.error-journal.harvest", owner: "ErrorJournalService.harvest",
                                                           interval: .seconds(300), tolerance: .seconds(120))])

        rig.service.start()
        #expect(rig.activities.scheduled.count == 1, "a second start scheduled a second activity")
        await rig.service.stop()
    }

    @Test func aRunWithNoChangeReadsNoSource() async throws {
        let rig = Rig()
        defer { rig.removeJournal() }
        rig.service.start()
        await rig.service.launchHarvest?.value

        #expect(await rig.activities.fire() == 1)
        #expect(rig.source.harvests == 1, "a run with no folder change read the sources")

        rig.folders.send(.items(["state.json"]), to: Self.chief)
        await rig.endWatches()
        #expect(await rig.activities.fire() == 1)
        #expect(rig.source.harvests == 1, "a change to an item that is not a watched log read the sources")
        await rig.service.stop()
    }

    @Test func aChangeToAWatchedLogHarvestsOnTheNextRunOnly() async throws {
        let rig = Rig()
        defer { rig.removeJournal() }
        rig.service.start()
        await rig.service.launchHarvest?.value

        rig.folders.send(.items(["client.log"]), to: Self.chief)
        await rig.endWatches()
        await rig.activities.fire()
        #expect(rig.source.harvests == 2, "a change to a watched log did not harvest on the next run")
        await rig.activities.fire()
        #expect(rig.source.harvests == 2, "one change harvested twice")
        await rig.service.stop()
    }

    @Test func anyNewReportOrARescanHarvests() async throws {
        for change in [FolderChange.items(["cmux-2026-10-27-120000.ips"]), .rescan] {
            let rig = Rig()
            defer { rig.removeJournal() }
            rig.service.start()
            await rig.service.launchHarvest?.value

            rig.folders.send(change, to: change == .rescan ? Self.chief : Self.reports)
            await rig.endWatches()
            await rig.activities.fire()
            #expect(rig.source.harvests == 2, "\(change) did not harvest on the next run")
            await rig.service.stop()
        }
    }

    @Test func oneHarvestRunsAtATime() async throws {
        let rig = Rig(released: false)
        defer { rig.removeJournal() }
        rig.service.start()
        await rig.source.waitForHarvests(1)

        rig.folders.send(.items(["host.log"]), to: Self.chief)
        await rig.endWatches()
        await rig.activities.fire()
        #expect(rig.source.harvests == 1, "a run started a harvest behind the one in flight")

        rig.source.release()
        await rig.service.launchHarvest?.value
        await rig.activities.fire()
        #expect(rig.source.harvests == 2, "the change seen during a harvest waited for no run")
        await rig.service.stop()
    }

    // MARK: Energy

    @Test func theSaverStretchesTheActivityAndAPauseHoldsIt() async throws {
        let energy = EnergyPolicySource()
        let rig = Rig(energy: energy)
        defer { rig.removeJournal() }
        rig.service.start()
        await rig.service.launchHarvest?.value

        energy.update(EnergyPolicy(saverReason: .setting))
        #expect(rig.activities.live.map(\.interval) == [.seconds(1200)], "the saver did not stretch the interval four times")
        #expect(rig.activities.live.map(\.tolerance) == [.seconds(480)])
        #expect(rig.activities.scheduled.count == 2, "the stretch did not replace the activity")

        energy.update(EnergyPolicy(saverReason: .setting, screensAsleep: true))
        #expect(rig.activities.live.isEmpty, "the activity kept running while the displays sleep")
        #expect(await rig.activities.fire() == 0)

        energy.update(.normal)
        #expect(rig.activities.live.map(\.interval) == [.seconds(300)], "the activity did not come back after the pause")
        #expect(rig.activities.scheduled.count == 3)
        await rig.service.stop()
    }

    @Test func stopInvalidatesTheActivityAndEndsTheWatches() async throws {
        let energy = EnergyPolicySource()
        let rig = Rig(energy: energy)
        defer { rig.removeJournal() }
        rig.service.start()
        await rig.service.launchHarvest?.value
        let watches = rig.service.watches
        #expect(watches.count == Self.watched.count)

        await rig.service.stop()
        #expect(rig.activities.live.isEmpty, "stop left the activity scheduled")
        for watch in watches { await watch.value }
        energy.update(EnergyPolicy(saverReason: .setting))
        #expect(rig.activities.scheduled.count == 1, "an energy change after stop scheduled an activity")
    }

    // MARK: Watches

    @Test func logsInOneFolderShareOneWatch() {
        let other = URL(fileURLWithPath: "/tmp/error-journal-tests/acpmux", isDirectory: true)
        let watches = ErrorJournalService.folderWatches(
            logs: [Self.chief.appendingPathComponent("host.log"), other.appendingPathComponent("daemon.log"),
                   Self.chief.appendingPathComponent("client.log")], reports: Self.reports)
        #expect(watches.map(\.folder.path) == [other.path, Self.chief.path, Self.reports.path])
        #expect(watches.map(\.names) == [["daemon.log"], ["host.log", "client.log"], nil])
        #expect(watches[1].matters(.items(["a.txt", "host.log"])))
        #expect(!watches[1].matters(.items(["a.txt"])))
        #expect(watches[1].matters(.rescan))
        #expect(watches[2].matters(.items(["anything.ips"])), "the reports folder watch skipped a report")
    }
}

/// One service on a hand-fired scheduler, hand-sent folder changes and a counting source.
@MainActor
private struct Rig {
    let source: GatedSource
    let activities: ManualBackgroundActivityScheduler
    let folders: HandFolderWatcher
    let directory: URL
    let service: ErrorJournalService

    init(energy: EnergyPolicySource = EnergyPolicySource(), released: Bool = true) {
        let watched = ErrorJournalServiceTests.watched
        let folders = HandFolderWatcher(folders: watched.map(\.folder))
        let directory = FileManager.default.temporaryDirectory.appending(path: "error-journal-service-\(UUID().uuidString)")
        let source = GatedSource(), activities = ManualBackgroundActivityScheduler()
        self.folders = folders
        self.directory = directory
        self.source = source
        self.activities = activities
        service = ErrorJournalService(journal: ErrorJournal(directory: directory), sources: [source], watched: watched,
                                      energy: energy, activities: activities, folders: folders,
                                      activityID: "test.error-journal.harvest")
        if released { source.release() }
    }

    /// Ends every folder's changes and returns once each watch has seen all it was sent.
    func endWatches() async {
        folders.finish()
        for watch in service.watches { await watch.value }
    }

    func removeJournal() { try? FileManager.default.removeItem(at: directory) }
}

/// Folder changes the test sends by hand, one stream for each folder made up front.
private nonisolated final class HandFolderWatcher: FolderWatching, Sendable {
    private let streams: [String: (stream: AsyncStream<FolderChange>, continuation: AsyncStream<FolderChange>.Continuation)]

    init(folders: [URL]) {
        var streams: [String: (stream: AsyncStream<FolderChange>, continuation: AsyncStream<FolderChange>.Continuation)] = [:]
        for folder in folders { streams[folder.standardizedFileURL.path] = AsyncStream<FolderChange>.makeStream() }
        self.streams = streams
    }

    func changes(in folder: URL) -> AsyncStream<FolderChange> {
        streams[folder.standardizedFileURL.path]?.stream ?? AsyncStream { $0.finish() }
    }

    func send(_ change: FolderChange, to folder: URL) {
        streams[folder.standardizedFileURL.path]?.continuation.yield(change)
    }

    func finish() {
        for entry in streams.values { entry.continuation.finish() }
    }
}

/// A source that counts its harvests; each one waits until the test releases the source.
private nonisolated final class GatedSource: ErrorHarvestSource, Sendable {
    let id = "gated"
    private struct State {
        var harvests = 0
        var released = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    var harvests: Int { state.withLock { $0.harvests } }

    func collect(after cursor: String?) async throws -> ErrorHarvest {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (resume, ready) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                state.harvests += 1
                let count = state.harvests
                let ready = state.watchers.filter { $0.count <= count }.map(\.continuation)
                state.watchers.removeAll { $0.count <= count }
                if state.released { return (true, ready) }
                state.waiting.append(continuation)
                return (false, ready)
            }
            for watcher in ready { watcher.resume() }
            if resume { continuation.resume() }
        }
        return ErrorHarvest(events: [], cursor: cursor)
    }

    /// Lets every waiting and later harvest finish.
    func release() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    /// Returns once `count` harvests have begun.
    func waitForHarvests(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if state.harvests >= count { return true }
                state.watchers.append((count, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }
}
