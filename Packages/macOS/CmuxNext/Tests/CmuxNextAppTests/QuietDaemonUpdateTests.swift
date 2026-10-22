import CmuxNextCompat
import CmuxNextDaemon
@testable import CmuxNextDaemonService
import Foundation
import Testing

/// A stale local cmux-tui restarts by itself at a quiet moment (`QuietDaemonUpdate`,
/// plans/cmux-next/server-updates-DESIGN.md rule 2): it waits while the person or the owner is
/// busy, tries again on owner events, when the app goes to the background and on bounded
/// deadlines, never forces a restart (an overdue wait shows the toast), restarts each daemon
/// process at most once per bundled build, and checks that the next daemon comes back on the
/// bundled build (one retry, then a failure for the notice). The person, the owner and the
/// restart are stand-ins here; the handoff itself is covered by the live tests.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct QuietDaemonUpdateTests {
    /// What the update reads and asks, shared with its closures.
    private nonisolated final class World: Sendable {
        private let state = Mutex((personIdle: false, ownerIdle: true, probes: 0, accepts: true, restarts: [Int32](), reconnects: 0))
        var personIdle: Bool {
            get { state.withLock { $0.personIdle } }
            set { state.withLock { $0.personIdle = newValue } }
        }
        var ownerIdle: Bool {
            get { state.withLock { $0.ownerIdle } }
            set { state.withLock { $0.ownerIdle = newValue } }
        }
        /// The owner probes so far.
        var probes: Int { state.withLock { $0.probes } }
        func probeOwner() -> Bool {
            state.withLock { state -> Bool in
                state.probes += 1
                return state.ownerIdle
            }
        }
        var accepts: Bool {
            get { state.withLock { $0.accepts } }
            set { state.withLock { $0.accepts = newValue } }
        }
        var restarts: [Int32] { state.withLock { $0.restarts } }
        var reconnects: Int { state.withLock { $0.reconnects } }
        func reconnect() { state.withLock { $0.reconnects += 1 } }

        func restart(_ identity: DaemonIdentity) -> Bool {
            state.withLock { state -> Bool in
                state.restarts.append(identity.pid)
                return state.accepts
            }
        }
    }

    private static let bundled = "b2b2b2b"
    private static let clientLeft = DaemonEvent.client(name: "client-detached", payload: .null)

    private static func update(_ world: World, clock: ManualClock = ManualClock(),
                               pacing: QuietDaemonUpdate.Pacing = .standard) -> QuietDaemonUpdate {
        QuietDaemonUpdate(pacing: pacing, clock: clock, isEnabled: { true }, userIsIdle: { world.personIdle },
                          ownerIsIdle: { _ in world.probeOwner() }, restart: { world.restart($0) }, reconnect: { world.reconnect() })
    }

    private static func daemon(pid: Int32, build: String? = "a1a1a1a", capabilities: [String] = []) -> DaemonIdentity {
        DaemonIdentity(buildCommit: build, capabilities: capabilities, pid: pid, generation: DaemonGeneration(rawValue: "g-\(pid)"))
    }

    /// Bounded wait for the restart's probe, which runs off the main actor.
    /// Until the update recorded `count` accepted restarts (its health check is armed), not only
    /// until the stand-in restart ran.
    private static func accepted(_ update: QuietDaemonUpdate, reach count: Int) async {
        for _ in 0..<400 where update.restarts < count {
            try? await Task.sleep(for: .milliseconds(5))  // test harness poll of the restart task
        }
    }

    private static func restarts(_ world: World, reach count: Int) async {
        for _ in 0..<400 where world.restarts.count < count {
            try? await Task.sleep(for: .milliseconds(5))  // test harness poll of the restart task
        }
    }

    @Test func staleMeansAnotherBuildOrWithNoBuildAMissingCapability() {
        let wanted: Set<String> = ["tab-groups-v1"]
        #expect(QuietDaemonUpdate.isStale(Self.daemon(pid: 1, build: "a1"), bundledBuild: "b2", appCapabilities: []))
        // The same build never restarts: its restart would gain nothing.
        #expect(!QuietDaemonUpdate.isStale(Self.daemon(pid: 1, build: "b2"), bundledBuild: "b2", appCapabilities: wanted))
        #expect(QuietDaemonUpdate.isStale(Self.daemon(pid: 1, build: nil), bundledBuild: "b2", appCapabilities: wanted))
        #expect(!QuietDaemonUpdate.isStale(Self.daemon(pid: 1, build: nil, capabilities: ["tab-groups-v1"]), bundledBuild: nil,
                                           appCapabilities: wanted))
    }

    @Test func itWaitsWhileThePersonIsBusyAndRestartsOnceTheyAreIdle() async {
        let world = World()
        let update = Self.update(world)
        update.consider(Self.daemon(pid: 10), bundledBuild: Self.bundled, appCapabilities: [])
        #expect(update.isWaiting)
        try? await Task.sleep(for: .milliseconds(50))  // let a wrongly started restart show
        #expect(world.restarts.isEmpty, "it restarted while the person was typing")

        // The app goes to the background (or the person stops typing): the next try restarts.
        world.personIdle = true
        update.tryNow()
        await Self.restarts(world, reach: 1)
        #expect(world.restarts == [10])
        #expect(update.isWaiting, "the toast came back before the successor connected")
    }

    @Test func itWaitsWhileTheOwnerIsBusyAndTriesAgainOnOwnerEvents() async {
        let world = World()
        world.personIdle = true
        world.ownerIdle = false
        let update = Self.update(world)
        update.consider(Self.daemon(pid: 11), bundledBuild: Self.bundled, appCapabilities: [])
        // The first try found the owner busy (under load it can start late: then it would see the idle owner below).
        for _ in 0..<400 where world.probes < 1 { try? await Task.sleep(for: .milliseconds(5)) }  // test harness poll
        #expect(world.probes >= 1, "the first try never probed the owner")
        try? await Task.sleep(for: .milliseconds(50))  // let a wrongly started restart show
        #expect(world.restarts.isEmpty, "it restarted under a CLI call or a chat")

        // An event that cannot end the business does nothing; a client leaving does.
        world.ownerIdle = true
        update.note(.client(name: "client-attached", payload: .null))
        try? await Task.sleep(for: .milliseconds(50))  // let a wrongly started restart show
        #expect(world.restarts.isEmpty)
        update.note(Self.clientLeft)
        await Self.restarts(world, reach: 1)
        #expect(world.restarts == [11])
    }

    @Test func itTriesAgainOnABoundedDeadline() async throws {
        let world = World()
        let clock = ManualClock()
        let update = Self.update(world, clock: clock)
        update.consider(Self.daemon(pid: 12), bundledBuild: Self.bundled, appCapabilities: [])
        try await clock.waitForSleepers(2)  // the overdue timer and the retry timer
        world.personIdle = true
        clock.advance(by: .seconds(60))
        await Self.restarts(world, reach: 1)
        #expect(world.restarts == [12])
    }

    @Test func eachDaemonRestartsAtMostOncePerBundledBuild() async {
        let world = World()
        world.personIdle = true
        world.accepts = false
        let update = Self.update(world)
        let stale = Self.daemon(pid: 13)
        update.consider(stale, bundledBuild: Self.bundled, appCapabilities: [])
        await Self.restarts(world, reach: 1)
        #expect(world.restarts == [13])
        // Refused: the toast may show, and the same daemon is not tried again on a reconnect.
        for _ in 0..<400 where update.isWaiting { try? await Task.sleep(for: .milliseconds(5)) }  // test harness poll
        #expect(!update.isWaiting)
        update.consider(Self.daemon(pid: 99, build: Self.bundled), bundledBuild: Self.bundled, appCapabilities: [])
        update.consider(stale, bundledBuild: Self.bundled, appCapabilities: [])
        #expect(!update.isWaiting)
        try? await Task.sleep(for: .milliseconds(50))  // let a wrongly started restart show
        #expect(world.restarts == [13])

        // Another daemon process is tried, once.
        world.accepts = true
        update.consider(Self.daemon(pid: 14), bundledBuild: Self.bundled, appCapabilities: [])
        await Self.restarts(world, reach: 2)
        #expect(world.restarts == [13, 14])
    }

    @Test func anUpToDateDaemonOrTheToggleOffSchedulesNothing() async {
        let world = World()
        world.personIdle = true
        let current = Self.update(world)
        current.consider(Self.daemon(pid: 15, build: Self.bundled), bundledBuild: Self.bundled, appCapabilities: [])
        #expect(!current.isWaiting)

        let off = QuietDaemonUpdate(pacing: .standard, clock: ManualClock(), isEnabled: { false }, userIsIdle: { true },
                                    ownerIsIdle: { _ in true }, restart: { world.restart($0) })
        off.consider(Self.daemon(pid: 16), bundledBuild: Self.bundled, appCapabilities: [])
        #expect(!off.isWaiting)
        try? await Task.sleep(for: .milliseconds(50))  // let a wrongly started restart show
        #expect(world.restarts.isEmpty)
    }

    @Test func anOldDaemonNextToAnAppUpdatedWhileItRunsRestartsAtAQuietMoment() async {
        let world = World()
        let update = Self.update(world)
        let daemon = Self.daemon(pid: 20, build: "a1a1a1a")
        // At launch the daemon matches the bundled build.
        update.consider(daemon, bundledBuild: "a1a1a1a", appCapabilities: [])
        #expect(!update.isWaiting)
        // The app is updated in place; the next handshake (a reconnect) reads the new bundled build.
        update.consider(daemon, bundledBuild: Self.bundled, appCapabilities: [])
        #expect(update.isWaiting)
        #expect(update.suppressesNotice)
        try? await Task.sleep(for: .milliseconds(50))  // let a wrongly started restart show
        #expect(world.restarts.isEmpty, "it restarted while the person was typing")
        world.personIdle = true
        update.tryNow()
        await Self.restarts(world, reach: 1)
        #expect(world.restarts == [20])
        // The successor on the bundled build passes the health check and ends the wait.
        update.consider(Self.daemon(pid: 21, build: Self.bundled), bundledBuild: Self.bundled, appCapabilities: [])
        #expect(!update.isWaiting)
        #expect(update.healthFailure == nil)
    }

    @Test func aWaitWithNoQuietMomentShowsTheToastAndKeepsWaiting() async throws {
        let world = World()
        let clock = ManualClock()
        let update = Self.update(world, clock: clock)
        update.consider(Self.daemon(pid: 22), bundledBuild: Self.bundled, appCapabilities: [])
        // The overdue deadline and the first retry's.
        try await clock.waitForSleepers(2)
        clock.advance(by: .seconds(30 * 60))
        for _ in 0..<400 where !update.isOverdue { try? await Task.sleep(for: .milliseconds(5)) }  // test harness poll
        #expect(update.isOverdue)
        #expect(update.isWaiting)
        #expect(!update.suppressesNotice, "the toast stays hidden while the person is never idle")
        #expect(world.restarts.isEmpty, "it forced a restart")
        // A quiet moment later still restarts.
        world.personIdle = true
        update.tryNow()
        await Self.restarts(world, reach: 1)
        #expect(world.restarts == [22])
    }

    @Test func aSuccessorThatNeverConnectsIsRetriedOnceThenReported() async throws {
        let world = World()
        world.personIdle = true
        let clock = ManualClock()
        let update = Self.update(world, clock: clock)
        update.consider(Self.daemon(pid: 23), bundledBuild: Self.bundled, appCapabilities: [])
        await Self.restarts(world, reach: 1)
        // The overdue deadline and the health check's.
        try await clock.waitForSleepers(2)
        clock.advance(by: .seconds(90))
        for _ in 0..<400 where world.reconnects == 0 { try? await Task.sleep(for: .milliseconds(5)) }  // test harness poll
        #expect(world.reconnects == 1)
        #expect(update.healthFailure == nil, "one missed deadline is retried, not reported")
        try await clock.waitForSleepers(2)
        clock.advance(by: .seconds(90))
        for _ in 0..<400 where update.healthFailure == nil { try? await Task.sleep(for: .milliseconds(5)) }  // test harness poll
        #expect(update.healthFailure != nil)
        #expect(world.reconnects == 1)
        #expect(!update.suppressesNotice)
    }

    @Test func aSuccessorOfAnotherBuildIsRestartedOnceMoreThenReported() async {
        let world = World()
        world.personIdle = true
        let update = Self.update(world)
        update.consider(Self.daemon(pid: 24), bundledBuild: Self.bundled, appCapabilities: [])
        await Self.accepted(update, reach: 1)
        // The successor runs another build still: one more restart.
        update.consider(Self.daemon(pid: 25, build: "c3c3c3c"), bundledBuild: Self.bundled, appCapabilities: [])
        #expect(update.healthFailure == nil)
        await Self.accepted(update, reach: 2)
        #expect(world.restarts == [24, 25])
        // Again: reported, and no third restart.
        update.consider(Self.daemon(pid: 26, build: "c3c3c3c"), bundledBuild: Self.bundled, appCapabilities: [])
        #expect(update.healthFailure != nil)
        #expect(!update.suppressesNotice)
        try? await Task.sleep(for: .milliseconds(50))  // let a wrongly started restart show
        #expect(world.restarts == [24, 25], "it kept restarting a daemon that does not come back on the bundled build")
    }
}
