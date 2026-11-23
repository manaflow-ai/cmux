@testable import CmuxNextCloud
import Foundation
import os
import Testing

/// The warm spare made ready ahead of its claim (``CloudSpareReadiness``): keyed once per app run and scope, never
/// recorded for a scope that changed meanwhile or a daemon that was not idle, and its link taken once by the session
/// of the same scope and team while it is kept; anything else ends the link.
@MainActor @Suite struct CloudSpareReadinessTests {
    /// The App's side, recorded: who is signed in, the keyed starts asked, the bound daemon run, the links made and ended.
    @MainActor final class World {
        var scope: CloudSpareReadiness.Scope = ["user_a", "team_a"]
        var keys: [String] = []
        /// What the keyed start answers (nil: not idle, or refused); `during` runs inside it (a switch meanwhile).
        var answer: String? = "run-1"
        var during: @MainActor () -> Void = {}
        var bound: [String: String] = [:]
        var links: [String] = []
        var up = true
        var fenced = false
        /// Whether a link's dial ahead connects, and the links whose dial was asked.
        var dialed = false
        var dials: [String] { dialLog.withLock { $0 } }
        private let dialLog = OSAllocatedUnfairLock<[String]>(initialState: [])
        /// Held shut, a link's coming up waits for it to open.
        var gate: AsyncStream<Void>?
        /// Held shut, a link's dial ahead waits for it to open.
        var dialGate: AsyncStream<Void>?
        /// Held shut, a keyed start waits for it to open.
        var keyGate: AsyncStream<Void>?
        let ended: AsyncStream<String>
        private let end: AsyncStream<String>.Continuation
        let made: AsyncStream<String>
        private let make: AsyncStream<String>.Continuation
        /// Each link whose dial ahead began.
        let dialsBegun: AsyncStream<String>
        private let dialing: AsyncStream<String>.Continuation
        /// Each machine whose keyed start began.
        let keysBegun: AsyncStream<String>
        private let keying: AsyncStream<String>.Continuation

        init() {
            (ended, end) = AsyncStream.makeStream(of: String.self)
            (made, make) = AsyncStream.makeStream(of: String.self)
            (dialsBegun, dialing) = AsyncStream.makeStream(of: String.self)
            (keysBegun, keying) = AsyncStream.makeStream(of: String.self)
        }

        /// No end comes after this: `ended` finishes.
        func finish() { end.finish() }

        func dependencies() -> CloudSpareReadiness.Dependencies {
            .init(scope: { [unowned self] in self.scope }, key: { [unowned self] machine, _ in
                self.keys.append(machine)
                self.keying.yield(machine)
                if let gate = self.keyGate { for await _ in gate { break } }
                self.during()
                if let answer = self.answer { self.bound[machine] = answer }
                return self.answer
            }, keyedInstance: { [unowned self] in self.bound[$0] }, link: { [unowned self] machine, _ in
                self.links.append(machine)
                let (isUp, isFenced, ends, gate) = (self.up, self.fenced, self.end, self.gate)
                let (isDialed, dialGate, dialing, dialLog) = (self.dialed, self.dialGate, self.dialing, self.dialLog)
                self.make.yield(machine)
                return .init(serve: World.serve(machine), fenced: { isFenced }, up: {
                    if let gate { for await _ in gate { break } }
                    return isUp
                }, dial: {
                    dialLog.withLock { $0.append(machine) }
                    dialing.yield(machine)
                    if let dialGate { for await _ in dialGate { break } }
                    return isDialed
                }, end: { _ = ends.yield(machine) })
            }, team: { nil })
        }

        /// A serve that never starts: nothing here asks for its socket.
        static func serve(_ machine: String) -> CloudCarrierServe {
            let dial = CloudCarrierDial(machine: machine, service: .mux)!
            return CloudCarrierServe(connector: .init(cli: URL(fileURLWithPath: "/nonexistent/cmux-tui"), dial: dial) { [:] }, socket: "/tmp/never-\(machine).sock")
        }
    }

    @Test func aPrimedSpareIsKeyedOnceForItsScopeAndRun() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(world.keys == ["vm_spare"])
        #expect(readiness.isKeyed("vm_spare", scope: ["user_a", "team_a"], instance: "run-1"))
        // Another prime (the next activation's warm, the spare's ready event) keys nothing again.
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(world.keys == ["vm_spare"])
        // A new daemon run (the key's binding moved) is not the run keyed ahead.
        #expect(!readiness.isKeyed("vm_spare", scope: ["user_a", "team_a"], instance: "run-2"))
        #expect(!readiness.isKeyed("vm_spare", scope: ["user_a", "team_a"], instance: "run-1"), "the stale entry is dropped")
    }

    @Test func aKeyAheadRunningAcrossAResetRecordsNothing() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        // Cloud is turned off while the keyed start runs: its answer comes back to a store that forgot everything.
        world.during = { readiness.reset() }
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(world.keys == ["vm_spare"])
        #expect(!readiness.isKeyed("vm_spare", scope: ["user_a", "team_a"], instance: "run-1"))
        // No link ahead outlives the reset either, whether it was made before it or would be after.
        #expect(!readiness.holdsLink("vm_spare"))
        // And a miss across a reset holds nothing back: the next prime keys at once.
        world.during = {}
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(world.keys == ["vm_spare", "vm_spare"])
        #expect(readiness.isKeyed("vm_spare", scope: ["user_a", "team_a"], instance: "run-1"))
    }

    /// Cloud is turned off after a prime was asked and before it ran: the account is the same, so only the reset says
    /// the prime is stale. It keys nothing and links nothing.
    @Test func aPrimeAskedBeforeAResetDoesNothingAfterIt() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        readiness.prime("vm_spare", team: "team_a")
        readiness.reset()
        await readiness.settled("vm_spare")
        #expect(world.keys.isEmpty && world.links.isEmpty)
        #expect(!readiness.isKeyed("vm_spare", scope: ["user_a", "team_a"], instance: "run-1") && !readiness.holdsLink("vm_spare"))
    }

    /// A prime that comes after a reset while the one from before it still runs is its own run: the spare is keyed
    /// and linked for the next start, not left to the old run, which writes nothing.
    @Test func aPrimeAfterAResetRunsWhileTheOldOneStillDoes() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        world.during = {
            world.during = {}
            readiness.reset()
            readiness.prime("vm_spare", team: "team_a")
        }
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare") // the run from before the reset
        await readiness.settled("vm_spare") // the one asked after it
        #expect(world.keys == ["vm_spare", "vm_spare"])
        #expect(readiness.isKeyed("vm_spare", scope: ["user_a", "team_a"], instance: "run-1"))
        #expect(readiness.holdsLink("vm_spare"))
    }

    @Test func anotherScopeOrSignedOutReadsAsNotKeyed() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(!readiness.isKeyed("vm_spare", scope: ["user_a", "team_b"], instance: "run-1"), "a team switch")
        #expect(!readiness.isKeyed("vm_spare", scope: ["user_a", "team_a"], instance: "run-1"), "dropped by the switch's read")
        #expect(!readiness.isKeyed("vm_other", scope: ["user_a", "team_a"], instance: "run-1"))
        world.scope = [nil, nil]
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(world.keys == ["vm_spare"], "signed out: no keyed start")
        #expect(world.links == ["vm_spare"], "signed out: no link")
    }

    @Test func aSwitchDuringTheKeyedStartRecordsNothing() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        world.during = { world.scope = ["user_b", "team_b"] }
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(!readiness.isKeyed("vm_spare", scope: ["user_a", "team_a"], instance: "run-1"))
        #expect(!readiness.isKeyed("vm_spare", scope: ["user_b", "team_b"], instance: "run-1"))
    }

    @Test func aBusyOrRefusingDaemonIsNotKeyed() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        world.answer = nil
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(world.keys == ["vm_spare"])
        #expect(!readiness.isKeyed("vm_spare", scope: ["user_a", "team_a"], instance: nil))
        // A prime right after does not ask again: every app activation primes, and a busy daemon is not read each time.
        var clock = ContinuousClock.now
        readiness.now = { clock }
        world.answer = "run-1"
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(world.keys == ["vm_spare"])
        // Past the hold the next prime asks again: a daemon that came up meanwhile is keyed then.
        clock = clock.advanced(by: CloudSpareReadiness.keyRetry + .seconds(1))
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(world.keys == ["vm_spare", "vm_spare"])
        #expect(readiness.isKeyed("vm_spare", scope: ["user_a", "team_a"], instance: "run-1"))
    }

    @Test func aResetForgetsAMissedKeySoTheNextAccountIsKeyedAtOnce() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        world.answer = nil
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        readiness.reset()
        world.answer = "run-1"
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(readiness.isKeyed("vm_spare", scope: ["user_a", "team_a"], instance: "run-1"))
    }

    /// 2026-11-21: every Cloud start ran its route check's one command on the machine (1.9 and 2.5 s of two starts on a
    /// warm spare). The spare's report is read once it is keyed, under the daemon run that holds the key, and given
    /// once, to the start of the same scope and run that claims it.
    @Test func aKeyedSparesRouteReportIsReadOnceAndTakenOnce() async {
        let world = World()
        var dependencies = world.dependencies(), reads: [String] = []
        dependencies.route = { machine in
            // Read after the keyed start, never before it: the keyed start restarts the agent service the report reads.
            #expect(world.bound[machine] == "run-1")
            reads.append(machine)
            return "report-1"
        }
        let readiness = CloudSpareReadiness(dependencies)
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(reads == ["vm_spare"])
        #expect(readiness.holdsRouteReport("vm_spare"))
        // Another prime (the next activation's warm) reads nothing again while one is held.
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(reads == ["vm_spare"])
        // Another machine has none; the spare's goes to the start that claims it, and to no start after it: a chat on
        // the machine can change what the report says.
        #expect(readiness.takeRouteReport("vm_other", scope: ["user_a", "team_a"], instance: "run-1") == nil)
        #expect(readiness.takeRouteReport("vm_spare", scope: ["user_a", "team_a"], instance: "run-1") == "report-1")
        #expect(readiness.takeRouteReport("vm_spare", scope: ["user_a", "team_a"], instance: "run-1") == nil)
        #expect(!readiness.holdsRouteReport("vm_spare"))
    }

    /// A report is this app's last keyed run's, for the scope it was read in, and at most as old as a link made ahead:
    /// a start of another scope, a signed-out one, one under another daemon run or one past the keep gets none, and
    /// the report is gone for the starts after it too.
    @Test func aRouteReportIsNotGivenToAnotherScopeAnotherRunOrPastItsKeep() async {
        let mine: CloudSpareReadiness.Scope = ["user_a", "team_a"]
        let others: [(CloudSpareReadiness.Scope, String?)] = [(["user_b", "team_a"], "run-1"), (["user_a", "team_b"], "run-1"), ([nil, nil], "run-1"),
                                                              ([], "run-1"), (["", "team_a"], "run-1"), (mine, "run-2"), (mine, nil)]
        for (scope, run) in others {
            let world = World()
            var dependencies = world.dependencies()
            dependencies.route = { _ in "report-1" }
            let readiness = CloudSpareReadiness(dependencies)
            readiness.prime("vm_spare", team: "team_a")
            await readiness.settled("vm_spare")
            #expect(readiness.takeRouteReport("vm_spare", scope: scope, instance: run) == nil, "\(scope) \(run ?? "no run")")
            #expect(readiness.takeRouteReport("vm_spare", scope: mine, instance: "run-1") == nil, "gone after \(scope) \(run ?? "no run")")
        }
        for (past, expected) in [(Duration.seconds(-1), "report-1" as String?), (.zero, nil)] {
            let world = World()
            var dependencies = world.dependencies()
            dependencies.route = { _ in "report-1" }
            let readiness = CloudSpareReadiness(dependencies)
            var clock = ContinuousClock.now
            readiness.now = { clock }
            readiness.prime("vm_spare", team: "team_a")
            await readiness.settled("vm_spare")
            clock = clock.advanced(by: CloudSpareReadiness.linkKept + past)
            #expect(readiness.holdsRouteReport("vm_spare") == (expected != nil))
            #expect(readiness.takeRouteReport("vm_spare", scope: mine, instance: "run-1") == expected)
        }
    }

    /// A report past its keep, or read under a daemon run that is no longer the keyed one, is read again by the next
    /// prime that finds the spare keyed.
    @Test func aRouteReportThatNoLongerFitsIsReadAgain() async {
        let world = World()
        var dependencies = world.dependencies(), reads = 0
        dependencies.route = { _ in reads += 1; return "report-\(reads)" }
        let readiness = CloudSpareReadiness(dependencies)
        var clock = ContinuousClock.now
        readiness.now = { clock }
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        clock = clock.advanced(by: CloudSpareReadiness.linkKept)
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(reads == 2)
        #expect(readiness.takeRouteReport("vm_spare", scope: ["user_a", "team_a"], instance: "run-1") == "report-2")
    }

    /// A spare that was not keyed (its daemon busy or not up) has no run to read a report under: no command runs there.
    @Test func aSpareThatIsNotKeyedReadsNoRouteAhead() async {
        let world = World()
        var dependencies = world.dependencies(), reads = 0
        dependencies.route = { _ in reads += 1; return "report-1" }
        world.answer = nil
        let readiness = CloudSpareReadiness(dependencies)
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(reads == 0)
        #expect(readiness.takeRouteReport("vm_spare", scope: ["user_a", "team_a"], instance: "run-1") == nil)
    }

    /// A read that gave no report (the command failed, the service was down) is not asked again on every app
    /// activation's prime, and a report read later is kept.
    @Test func aRouteReadThatGaveNoReportWaitsBeforeTheNext() async {
        let world = World()
        var dependencies = world.dependencies(), reads = 0, answer: String?
        dependencies.route = { _ in reads += 1; return answer }
        let readiness = CloudSpareReadiness(dependencies)
        var clock = ContinuousClock.now
        readiness.now = { clock }
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(reads == 1)
        #expect(!readiness.holdsRouteReport("vm_spare"))
        answer = "report-1"
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(reads == 1)
        clock = clock.advanced(by: CloudSpareReadiness.keyRetry + .seconds(1))
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(reads == 2)
        #expect(readiness.takeRouteReport("vm_spare", scope: ["user_a", "team_a"], instance: "run-1") == "report-1")
    }

    /// A report whose read ran across a new daemon run, an account switch or a reset is not that run's or that
    /// account's: nothing is kept, and the start reads its own.
    @Test func aRouteReadAcrossANewRunASwitchOrAResetRecordsNothing() async {
        for change in ["run", "scope", "reset"] {
            let world = World()
            var dependencies = world.dependencies()
            var readiness: CloudSpareReadiness?
            dependencies.route = { machine in
                switch change {
                case "run": world.bound[machine] = "run-2"
                case "scope": world.scope = ["user_b", "team_b"]
                default: readiness?.reset()
                }
                return "report-1"
            }
            let made = CloudSpareReadiness(dependencies)
            readiness = made
            made.prime("vm_spare", team: "team_a")
            await made.settled("vm_spare")
            #expect(!made.holdsRouteReport("vm_spare"), "\(change)")
            for (scope, run) in [(["user_a", "team_a"], "run-1"), (["user_a", "team_a"], "run-2"), (["user_b", "team_b"], "run-1")] {
                #expect(made.takeRouteReport("vm_spare", scope: scope, instance: run) == nil, "\(change): \(scope) \(run)")
            }
        }
    }

    /// A reset (Cloud turned off, signed out, another account) forgets a report read ahead.
    @Test func aResetForgetsTheRouteReport() async {
        let world = World()
        var dependencies = world.dependencies()
        dependencies.route = { _ in "report-1" }
        let readiness = CloudSpareReadiness(dependencies)
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        readiness.reset()
        #expect(readiness.takeRouteReport("vm_spare", scope: ["user_a", "team_a"], instance: "run-1") == nil)
    }

    /// With no route read supplied (an app that reads none ahead), a prime keys and links as before.
    @Test func noRouteReadSuppliedReadsNothing() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(readiness.isKeyed("vm_spare", scope: ["user_a", "team_a"], instance: "run-1"))
        #expect(readiness.takeRouteReport("vm_spare", scope: ["user_a", "team_a"], instance: "run-1") == nil)
    }

    @Test func theClaimedSpareSessionTakesItsLinkOnce() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(readiness.holdsLink("vm_spare"))
        // A second prime keeps the one link.
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(world.links == ["vm_spare"])
        #expect(readiness.link(for: "vm_spare", team: "team_a") != nil)
        #expect(readiness.link(for: "vm_spare", team: "team_a") == nil, "taken once")
        #expect(readiness.link(for: "vm_other", team: "team_a") == nil)
    }

    @Test func aLinkTakenWhileItComesUpIsNotEnded() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        world.gate = gate
        readiness.prime("vm_spare", team: "team_a")
        _ = await firstValue(world.made)
        // The claim's session comes first: it takes the serve and connects on it itself.
        #expect(readiness.link(for: "vm_spare", team: "team_a") != nil)
        open.yield()
        await readiness.settled("vm_spare")
        world.finish()
        var ends: [String] = []
        for await machine in world.ended { ends.append(machine) }
        #expect(ends.isEmpty, "the prime ended the link its session took")
    }

    /// The warm's prime dials its machine on the link that is up, once: the session that takes it has only a stream
    /// left to open.
    @Test func theWarmsPrimeDialsItsLinkOnce() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        world.dialed = true
        readiness.prime("vm_spare", team: "team_a", dials: true)
        await readiness.settled("vm_spare")
        readiness.prime("vm_spare", team: "team_a", dials: true)
        await readiness.settled("vm_spare")
        #expect(world.links == ["vm_spare"])
        #expect(world.dials == ["vm_spare"])
        #expect(readiness.link(for: "vm_spare", team: "team_a") != nil)
    }

    /// A dial that did not connect is not asked again, and leaves the link for its session, whose own connect dials.
    @Test func aLinkWhoseDialDidNotConnectIsStillTakenAndNotDialedAgain() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        readiness.prime("vm_spare", team: "team_a", dials: true)
        await readiness.settled("vm_spare")
        readiness.prime("vm_spare", team: "team_a", dials: true)
        await readiness.settled("vm_spare")
        #expect(world.dials == ["vm_spare"])
        #expect(readiness.link(for: "vm_spare", team: "team_a") != nil)
    }

    /// Any other prime (the service's "spare ready") links and keys, and dials nothing: only a warm or a compose's
    /// reserve says a chat is about to start.
    @Test func aPrimeThatDoesNotDialLinksOnly() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(world.links == ["vm_spare"])
        #expect(world.dials.isEmpty)
        // The warm's prime then dials the link already held.
        readiness.prime("vm_spare", team: "team_a", dials: true)
        await readiness.settled("vm_spare")
        #expect(world.links == ["vm_spare"])
        #expect(world.dials == ["vm_spare"])
    }

    @Test func aLinkThatDoesNotComeUpIsNotDialed() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        world.up = false
        readiness.prime("vm_spare", team: "team_a", dials: true)
        await readiness.settled("vm_spare")
        #expect(world.dials.isEmpty)
    }

    @Test func aLinkTakenWhileItDialsIsNotEnded() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        (world.dialGate, world.dialed) = (gate, true)
        readiness.prime("vm_spare", team: "team_a", dials: true)
        _ = await firstValue(world.dialsBegun)
        // The claim's session comes while the serve dials: it takes the serve and its connect joins that dial.
        #expect(readiness.link(for: "vm_spare", team: "team_a") != nil)
        open.yield()
        await readiness.settled("vm_spare")
        world.finish()
        var ends: [String] = []
        for await machine in world.ended { ends.append(machine) }
        #expect(ends.isEmpty, "the prime ended the link its session took")
        #expect(!readiness.holdsLink("vm_spare"))
    }

    /// A prime that dials (the warm's, a reserve's) names the machine's own team, the one its session asks for: it
    /// replaces a link made for another team, and a prime that does not dial keeps it.
    @Test func theWarmsTeamReplacesAnotherAndIsKept() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        world.dialed = true
        readiness.prime("vm_spare", team: "team_app")
        await readiness.settled("vm_spare")
        readiness.prime("vm_spare", team: "team_service", dials: true)
        await readiness.settled("vm_spare")
        #expect(world.links == ["vm_spare", "vm_spare"], "the link made for another team was replaced")
        #expect(await firstValue(world.ended) == "vm_spare")
        readiness.prime("vm_spare", team: "team_app")
        await readiness.settled("vm_spare")
        #expect(world.links == ["vm_spare", "vm_spare"], "the warm's link is kept")
        #expect(world.dials == ["vm_spare"])
        #expect(readiness.link(for: "vm_spare", team: "team_service") != nil)
    }

    /// A warm's prime that comes while another prime still keys the spare (seconds) links and dials beside it.
    @Test func aWarmsPrimeDuringAnotherPrimeDialsBesideIt() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        (world.keyGate, world.dialed) = (gate, true)
        readiness.prime("vm_spare", team: "team_a")
        _ = await firstValue(world.keysBegun)
        readiness.prime("vm_spare", team: "team_a", dials: true)
        #expect(await firstValue(world.dialsBegun) == "vm_spare", "dialed while the first prime still keys")
        open.yield()
        await readiness.settled("vm_spare")
        #expect(world.links == ["vm_spare"], "one link for both primes")
        #expect(world.dials == ["vm_spare"])
        #expect(readiness.isKeyed("vm_spare", scope: ["user_a", "team_a"], instance: "run-1"))
        #expect(readiness.link(for: "vm_spare", team: "team_a") != nil)
    }

    @Test func aLinkOfAnotherTeamIsEndedNotTaken() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(readiness.link(for: "vm_spare", team: "team_b") == nil)
        #expect(await firstValue(world.ended) == "vm_spare")
    }

    /// A prime that names no team links in ``CloudSpareReadiness/Dependencies/team`` (the install token's), the team the
    /// claim's record is in, so the claim takes it; the App's active team (another one) would have ended it.
    @Test func aPrimeWithNoTeamLinksInTheSparesTeamAndTheClaimTakesIt() async {
        let world = World()
        var dependencies = world.dependencies()
        var linkedTeams: [String?] = []
        let link = dependencies.link
        dependencies.link = { machine, team in linkedTeams.append(team); return link(machine, team) }
        dependencies.team = { "team_install" }
        let readiness = CloudSpareReadiness(dependencies)
        readiness.prime("vm_spare")
        await readiness.settled("vm_spare")
        #expect(linkedTeams == ["team_install"])
        // The wire's prime (no team either) keeps the one link.
        readiness.prime("vm_spare")
        await readiness.settled("vm_spare")
        #expect(world.links == ["vm_spare"])
        #expect(readiness.link(for: "vm_spare", team: "team_install") != nil)
    }

    /// The claim asks for the link while its prime still reads the team (a token mint): the claim links its own, so the
    /// prime dials no second serve nobody would take; the keying goes on beside it.
    @Test func aClaimDuringTheTeamReadLeavesThePrimeLinkingNothing() async {
        let world = World()
        var dependencies = world.dependencies()
        var claim: @MainActor () -> Void = {}
        dependencies.team = { claim(); return "team_install" }
        let readiness = CloudSpareReadiness(dependencies)
        claim = { #expect(readiness.link(for: "vm_spare", team: "team_install") == nil) }
        readiness.prime("vm_spare")
        await readiness.settled("vm_spare")
        #expect(world.links.isEmpty)
        #expect(world.keys == ["vm_spare"])
        // A later prime (the next warm) links again.
        claim = {}
        readiness.prime("vm_spare")
        await readiness.settled("vm_spare")
        #expect(world.links == ["vm_spare"])
    }

    /// A reserve's prime names no team and dials: its link is made and dialed in the spare's team, the warm's prime
    /// (the same team, named by the service) keeps that link and dials nothing more, and the claim takes it.
    @Test func aDialingPrimeWithNoTeamDialsInTheSparesTeam() async {
        let world = World()
        var dependencies = world.dependencies()
        var linkedTeams: [String?] = []
        let link = dependencies.link
        dependencies.link = { machine, team in linkedTeams.append(team); return link(machine, team) }
        dependencies.team = { "team_install" }
        world.dialed = true
        let readiness = CloudSpareReadiness(dependencies)
        readiness.prime("vm_spare", dials: true)
        await readiness.settled("vm_spare")
        readiness.prime("vm_spare", team: "team_install", dials: true)
        await readiness.settled("vm_spare")
        #expect(linkedTeams == ["team_install"])
        #expect(world.dials == ["vm_spare"])
        #expect(readiness.link(for: "vm_spare", team: "team_install") != nil)
    }

    /// The claim takes the first prime's link while a dialing prime that joined it still reads the team: that prime
    /// makes no second link, which nobody would take.
    @Test func aClaimThatTookTheLinkLeavesAJoinedPrimeLinkingNothing() async {
        let world = World()
        var dependencies = world.dependencies()
        let (teamGate, teamOpen) = AsyncStream.makeStream(of: Void.self)
        let (keyGate, keyOpen) = AsyncStream.makeStream(of: Void.self)
        let (reading, read) = AsyncStream.makeStream(of: String.self)
        var reads = 0
        dependencies.team = {
            reads += 1
            if reads == 2 {
                read.yield("second")
                for await _ in teamGate { break }
            }
            return "team_install"
        }
        (world.keyGate, world.dialed) = (keyGate, true)
        let readiness = CloudSpareReadiness(dependencies)
        // The wire's prime links and still keys; the reserve's prime joins it and reads the team.
        readiness.prime("vm_spare")
        #expect(await firstValue(world.made) == "vm_spare")
        readiness.prime("vm_spare", dials: true)
        #expect(await firstValue(reading) == "second")
        #expect(readiness.link(for: "vm_spare", team: "team_install") != nil)
        teamOpen.yield()
        keyOpen.yield()
        await readiness.settled("vm_spare")
        #expect(world.links == ["vm_spare"], "no second link after the claim took the first")
        #expect(world.dials.isEmpty)
        // The next prime (another spare's warm, or this machine's next one) links again.
        readiness.prime("vm_spare", dials: true)
        await readiness.settled("vm_spare")
        #expect(world.links == ["vm_spare", "vm_spare"])
    }

    /// A dialing prime whose team could not be read keeps the link held for the spare's team.
    @Test func aDialingPrimeWithNoReadableTeamKeepsTheLinkHeld() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        world.dialed = true
        readiness.prime("vm_spare", team: "team_install", dials: true)
        await readiness.settled("vm_spare")
        readiness.prime("vm_spare", dials: true)
        await readiness.settled("vm_spare")
        #expect(world.links == ["vm_spare"])
        #expect(world.dials == ["vm_spare"])
        #expect(readiness.link(for: "vm_spare", team: "team_install") != nil)
    }

    /// The claim asks while a dialing prime still reads the team: nothing is linked and nothing is dialed.
    @Test func aClaimDuringTheTeamReadLeavesADialingPrimeDialingNothing() async {
        let world = World()
        var dependencies = world.dependencies()
        var claim: @MainActor () -> Void = {}
        dependencies.team = { claim(); return "team_install" }
        world.dialed = true
        let readiness = CloudSpareReadiness(dependencies)
        claim = { #expect(readiness.link(for: "vm_spare", team: "team_install") == nil) }
        readiness.prime("vm_spare", dials: true)
        await readiness.settled("vm_spare")
        #expect(world.links.isEmpty)
        #expect(world.dials.isEmpty)
    }

    @Test func aLinkPastItsKeepIsEndedNotTaken() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        var clock = ContinuousClock.now
        readiness.now = { clock }
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        clock = clock.advanced(by: CloudSpareReadiness.linkKept)
        #expect(!readiness.holdsLink("vm_spare"))
        #expect(readiness.link(for: "vm_spare", team: "team_a") == nil)
        #expect(await firstValue(world.ended) == "vm_spare")
    }

    @Test func aLinkOfAnEndedAccountIsEndedNotTaken() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        world.fenced = true
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(readiness.link(for: "vm_spare", team: "team_a") == nil)
        #expect(await firstValue(world.ended) == "vm_spare")
    }

    @Test func aLinkThatDoesNotComeUpIsEndedAndNotKept() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        world.up = false
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(!readiness.holdsLink("vm_spare"))
        #expect(await firstValue(world.ended) == "vm_spare")
    }

    @Test func aSignOutLeavesNoLinkToTake() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        world.scope = ["user_a", "team_b"]
        #expect(readiness.link(for: "vm_spare", team: "team_a") == nil)
        #expect(await firstValue(world.ended) == "vm_spare")
    }

    /// What `CloudService` runs when the account or team changes, the person signs out or Cloud is turned off: the held
    /// link (`carrier serve`) ends at once, not at the next prime or take, and nothing reads as keyed.
    @Test func aResetEndsTheHeldLinkAndForgetsTheKey() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(readiness.holdsLink("vm_spare"))
        readiness.reset()
        #expect(await firstValue(world.ended) == "vm_spare")
        #expect(!readiness.holdsLink("vm_spare"))
        #expect(!readiness.isKeyed("vm_spare", scope: ["user_a", "team_a"], instance: "run-1"))
        #expect(readiness.link(for: "vm_spare", team: "team_a") == nil)
    }

    /// The App's link is fenced by the account's end, as the session's own carrier is.
    @Test func theSpareLinkFollowsItsAccountsFence() throws {
        let streams = CloudCarrierStreams()
        let dial = try #require(CloudCarrierDial(machine: "vm_spare", service: .mux))
        let connector = CloudCarrierDial.Connector(cli: URL(fileURLWithPath: "/nonexistent/cmux-tui"), dial: dial, streams: streams) { [:] }
        let link = CloudSpareReadiness.SpareLink(spare: connector, paths: CloudPaths(root: FileManager.default.temporaryDirectory))
        #expect(!link.fenced())
        _ = streams.endAll()
        #expect(link.fenced())
    }
}

/// The warm's answer names its spare whether or not a login copy goes with it; a teammate's spare, a refusal or no
/// spare names none.
@Suite struct CloudWarmedSpareTests {
    @Test func theWarmNamesTheOwnersSpare() {
        let fresh: [String: Any] = ["ok": true, "machine": "vm_s", "team": "team_a", "fresh": true, "vm_kind": "owner",
                                    "copy": ["machine": "vm_s", "account": "user_a", "team": "team_a", "generation": "g1"]]
        #expect(CloudMoveCLI.warmedSpare(fresh, account: "user_a") == .init(machineID: "vm_s", team: "team_a",
                copy: .init(machineID: "vm_s", account: "user_a", team: "team_a", generation: "g1")))
        let replay: [String: Any] = ["ok": true, "machine": "vm_s", "team": "team_a", "fresh": false]
        #expect(CloudMoveCLI.warmedSpare(replay, account: "user_a") == .init(machineID: "vm_s", team: "team_a", copy: nil))
    }

    @Test func noSpareATeammatesOrARefusalNamesNone() {
        #expect(CloudMoveCLI.warmedSpare(["ok": true, "machine": NSNull(), "reason": "none"], account: "user_a") == nil)
        #expect(CloudMoveCLI.warmedSpare(["ok": true, "machine": "vm_s", "vm_kind": "team"], account: "user_a") == nil)
        #expect(CloudMoveCLI.warmedSpare(["ok": false, "error_code": "team_unresolved"], account: "user_a") == nil)
        #expect(CloudMoveCLI.warmedSpare(nil, account: "user_a") == nil)
        // A copy for another account is never handed out.
        let other: [String: Any] = ["ok": true, "machine": "vm_s", "copy": ["machine": "vm_s", "account": "user_b", "team": "team_a"]]
        #expect(CloudMoveCLI.warmedSpare(other, account: "user_a")?.copy == nil)
    }
}

/// A `cloud start-session` run tells the App it began before its work runs (the App warms the spare its create
/// claims); a caller that joins the run starts none.
@MainActor @Suite struct CloudStartRunsBeganTests {
    @Test func aNewRunTellsItsStartBeforeItsWork() async throws {
        let runs = CloudStartRuns<Int, Int>()
        var began: [String] = []
        runs.began = { began.append($0.machine) }
        let key = CloudStartRunKey(machine: "name:chats", agent: "claude", cwd: nil, caller: nil, account: ["user_a", "team_a"])
        let answer = try await runs.answer(key, within: .seconds(30), pending: 0, forgotten: CancellationError()) {
            #expect(began == ["name:chats"], "told before the work")
            return 7
        }
        #expect(answer == 7)
        #expect(began == ["name:chats"])
    }
}

/// The stream's first value. An iterator, not `first(where:)`: that closure is not Sendable under Swift 6
/// (#SendingRisksDataRace).
private func firstValue(_ stream: AsyncStream<String>) async -> String? {
    var values = stream.makeAsyncIterator()
    return await values.next()
}
