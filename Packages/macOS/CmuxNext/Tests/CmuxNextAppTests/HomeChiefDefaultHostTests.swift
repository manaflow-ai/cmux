import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextHomeEngine
@testable import CmuxNextHostedChief
import Foundation
import Observation
import Testing

/// What the default Chief (#64) reads and starts: whether this Mac's optchat-chief runs, kept
/// current by the brain keeper's events, and that showing the Hosted Chief never starts it (a
/// started host would turn Auto into this Mac's Chief on the next Chief tab check).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct HomeChiefDefaultHostTests {
    // MARK: Showing the Hosted Chief starts no host

    @Test func showingTheHostedChiefNeverStartsThisMacsHost() {
        let home = HomeChiefDefaultTests.services().home
        home.noteCloudChiefsChecked()
        home.setCloudChiefs(HomeCloudChiefs(hosted: HomeChiefDefaultTests.hosted))
        home.localChiefRunning = false
        #expect(!home.startsLocalBrain(for: "conv_hosted"), "the Hosted Chief's conversation")
        #expect(!home.startsLocalBrain(for: nil), "Home itself (a reconnect, Channels) while the default resolves to Hosted")
        #expect(!home.startsLocalBrain(for: HomeChiefDefaultTests.local), "this Mac's Chief, shown: a message to it starts the host")
        // Auto resolves to this Mac's Chief: Home itself keeps its host running; the Hosted Chief still starts none.
        home.localChiefRunning = true
        #expect(home.startsLocalBrain(for: nil))
        #expect(!home.startsLocalBrain(for: "conv_hosted"))
        // Signed out (no cloud Chief): Home's Chief is this Mac's, so Home starts it as before.
        home.setCloudChiefs(HomeCloudChiefs())
        home.localChiefRunning = false
        #expect(home.startsLocalBrain(for: nil))
    }

    /// At launch Home can show this Mac's Chief before the first Chief tab check reads the cloud Chiefs; a
    /// host started then would keep Auto on this Mac's Chief once the Hosted Chief is known.
    @Test func beforeTheCloudChiefsAreReadHomeStartsNoHost() {
        let home = HomeChiefDefaultTests.services().home
        let starts = Self.recordStarts(home)
        home.signedInToCloud = { true }
        home.localChiefRunning = false
        #expect(!home.startsLocalBrain(for: nil))
        #expect(!home.startsLocalBrain(for: HomeChiefDefaultTests.local), "Home's first conversation, the Hosted Chief not known yet")
        home.ensureLocalBrain(asked: true, for: HomeChiefDefaultTests.local)
        #expect(home.waitingHomeAsk == true, "the ask waits for the check")
        #expect(starts.value.isEmpty)
        // The check finds the Hosted Chief: the waited ask starts nothing, and Home keeps showing the Hosted Chief.
        home.setCloudChiefs(HomeCloudChiefs(hosted: HomeChiefDefaultTests.hosted))
        home.noteCloudChiefsChecked()
        #expect(home.waitingHomeAsk == nil)
        #expect(starts.value.isEmpty, "no host starts under the Hosted Chief")
        #expect(home.cloudChief == HomeChiefDefaultTests.hosted)
        #expect(!home.startsLocalBrain(for: nil))
        #expect(!home.startsLocalBrain(for: HomeChiefDefaultTests.local), "this Mac's Chief, shown: a message to it starts the host")
        // Signed in without a cloud Chief: Home's Chief is this Mac's and starts as before.
        home.setCloudChiefs(HomeCloudChiefs())
        #expect(home.startsLocalBrain(for: nil))
    }

    /// Signed in without a cloud Chief: the check finds none, so the ask that waited starts this Mac's host.
    @Test func aCheckThatFindsNoHostedChiefStartsTheWaitedHost() {
        let home = HomeChiefDefaultTests.services().home
        let starts = Self.recordStarts(home)
        home.signedInToCloud = { true }
        home.ensureLocalBrain(asked: true, for: nil)
        #expect(starts.value.isEmpty)
        home.noteCloudChiefsChecked()
        #expect(starts.value == [true], "the waited ask starts the host, still asked")
        #expect(home.waitingHomeAsk == nil)
    }

    /// While this Mac's history is still being copied into the Hosted Chief, the Chief tab shows this Mac's
    /// Chief (``HomeService/tabChiefs``), but the Hosted Chief is known: no host starts, so Auto still
    /// gives the Hosted Chief the tab once the copy settles (review of #23813).
    @Test func thePendingHistoryCopyStartsNoHost() throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = HomeChiefDefaultTests.services().home
        let starts = Self.recordStarts(home)
        Self.wire(home.hostedChief, home: ChiefHome(root: root, isolated: true))
        home.signedInToCloud = { true }
        home.localChiefRunning = false
        home.ensureLocalBrain(asked: false, for: nil)
        home.setCloudChiefs(HomeCloudChiefs(hosted: HomeChiefDefaultTests.hosted))
        home.hostedChief.start(HomeChiefDefaultTests.hosted)
        try #require(home.hostedChief.pending, "the one copy is due")
        #expect(home.cloudChief == nil, "this Mac's Chief keeps the tab while the copy runs")
        home.noteCloudChiefsChecked()
        #expect(starts.value.isEmpty, "the waited ask starts no host under the Hosted Chief")
        #expect(!home.startsLocalBrain(for: nil), "Home itself (a reconnect) starts none either")
        #expect(!home.startsLocalBrain(for: HomeChiefDefaultTests.local), "nor the Chief tab, which shows this Mac's Chief meanwhile")
    }

    // MARK: The running state follows the brain keeper

    @Test func theKeepersReportChangesTheDefaultChief() {
        let home = HomeChiefDefaultTests.services().home
        home.setCloudChiefs(HomeCloudChiefs(hosted: HomeChiefDefaultTests.hosted))
        home.localChiefRunning = true
        #expect(home.cloudChief == nil)
        // HomeService.start's Chief tab check observes the default Chief: a change of it re-runs the check.
        let fired = ChiefDefaultFlag()
        withObservationTracking { _ = home.prefersLocalChief } onChange: { fired.set() }
        // The keeper saw the host exit for good (a crash past its retries, `cmux chief shutdown`).
        home.wireChiefDefault()
        home.brain.onHostChange?(false)
        #expect(fired.value, "the default Chief's observers hear the change")
        #expect(home.cloudChief == HomeChiefDefaultTests.hosted, "Auto falls back to the Hosted Chief")
        // No change, nothing to hear.
        let again = ChiefDefaultFlag()
        withObservationTracking { _ = home.prefersLocalChief } onChange: { again.set() }
        home.noteLocalChiefHost(running: false)
        #expect(!again.value)
    }

    @Test func theBrainWatchReportsAHostAndItsExit() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = ChiefHome(root: root, isolated: true)
        // `cmux chief shutdown` stopped it: the watch does not start it again.
        try FileManager.default.createDirectory(at: home.shutdownMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: home.shutdownMarker)
        let host = try Self.fakeHost(in: root)
        let (events, report) = AsyncStream<Bool>.makeStream()
        let watch = ChiefBrainWatch(home: home) { nil }
        watch.onChange = { report.yield($0) }
        var next = events.makeAsyncIterator()
        watch.watch(host.processIdentifier)
        #expect(await next.next() == true, "a watched host runs")
        await Self.end(host)
        #expect(await next.next() == false, "its exit, not restarted, is reported")
    }

    // MARK: localChiefRuns reads the lock

    @Test func theLockCountsOnlyWhileItsOptchatChiefLives() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = ChiefHome(root: root, isolated: true)
        let none = await HomeService.localChiefRuns(home)
        #expect(!none, "no lock")
        let host = try Self.fakeHost(in: root)
        try Self.writeLock(host.processIdentifier, home: home)
        let live = await HomeService.localChiefRuns(home)
        #expect(live, "a live optchat-chief holds the lock")
        await Self.end(host)
        let dead = await HomeService.localChiefRuns(home)
        #expect(!dead, "the lock names a dead pid")
        // A live process that is not an optchat-chief (this test runner) never counts.
        try Self.writeLock(ProcessInfo.processInfo.processIdentifier, home: home)
        let other = await HomeService.localChiefRuns(home)
        #expect(!other)
    }

    // MARK: The two histories

    /// The Hosted Chief gets this Mac's history once (``HostedChiefMigration``). A switch to this
    /// Mac's Chief and back never copies again, so what was said to one stays with that one.
    @Test func thisMacsHistoryReachesTheHostedChiefOnlyOnce() throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = ChiefHome(root: root, isolated: true)
        let hosted = HomeChiefDefaultTests.hosted
        let first = Self.migration(home: home)
        first.start(hosted)
        #expect(first.pending, "before the copy: the one copy is due")
        HostedChiefLedger(session: home.session).mark(.history, chief: hosted.id)
        // Later starts (every connect, after any number of messages to this Mac's Chief) copy nothing.
        let later = Self.migration(home: home)
        later.start(hosted)
        #expect(!later.pending, "after the copy: no copy is due again")
    }

    // MARK: Helpers

    static func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("chief-default-\(UUID().uuidString)", isDirectory: true)
    }

    /// A process named `optchat-chief` (a copy of /bin/sleep), as `ChiefHostStop.isChiefHost` reads names.
    static func fakeHost(in root: URL) throws -> Process {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent(HomeBrainHost.bundledChiefName)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["60"]
        try process.run()
        return process
    }

    static func end(_ process: Process) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in done.resume() }
            process.terminate()
        }
    }

    static func writeLock(_ pid: pid_t, home: ChiefHome) throws {
        let lock = home.root.appendingPathComponent("state/host.lock")
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(pid)\n".utf8).write(to: lock)
    }

    static func migration(home: ChiefHome) -> HostedChiefMigration {
        let migration = HostedChiefMigration()
        wire(migration, home: home)
        return migration
    }

    static func wire(_ migration: HostedChiefMigration, home: ChiefHome) {
        migration.wire(.init(apiBase: { URL(fileURLWithPath: "/dev/null") }, token: { throw CancellationError() },
                             ops: { _ in throw CancellationError() }, user: { "user_default_chief" }, debugBuild: false,
                             owner: ChiefConversationOwner(home: home), localChief: "agent_mux", refreshTab: {}))
    }

    /// Records each start of this Mac's brain host instead of starting it (its `asked`).
    private static func recordStarts(_ home: HomeService) -> ChiefDefaultStarts {
        let starts = ChiefDefaultStarts()
        home.startsBrain = { starts.append($0) }
        return starts
    }
}

/// A flag an Observation change sets (its handler runs on whichever thread changed the value).
private nonisolated final class ChiefDefaultFlag: Sendable {
    private let state = Mutex(false)
    var value: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}

/// The brain host starts a test recorded (``HomeChiefDefaultHostTests/recordStarts(_:)``).
@MainActor private final class ChiefDefaultStarts {
    private(set) var value: [Bool] = []
    func append(_ asked: Bool) { value.append(asked) }
}
