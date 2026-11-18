@testable import CmuxNextCloud
import Foundation
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
        /// Held shut, a link's coming up waits for it to open.
        var gate: AsyncStream<Void>?
        let ended: AsyncStream<String>
        private let end: AsyncStream<String>.Continuation
        let made: AsyncStream<String>
        private let make: AsyncStream<String>.Continuation

        init() {
            (ended, end) = AsyncStream.makeStream(of: String.self)
            (made, make) = AsyncStream.makeStream(of: String.self)
        }

        /// No end comes after this: `ended` finishes.
        func finish() { end.finish() }

        func dependencies() -> CloudSpareReadiness.Dependencies {
            .init(scope: { [unowned self] in self.scope }, key: { [unowned self] machine, _ in
                self.keys.append(machine)
                self.during()
                if let answer = self.answer { self.bound[machine] = answer }
                return self.answer
            }, keyedInstance: { [unowned self] in self.bound[$0] }, link: { [unowned self] machine, _ in
                self.links.append(machine)
                let (isUp, isFenced, ends, gate) = (self.up, self.fenced, self.end, self.gate)
                self.make.yield(machine)
                return .init(serve: World.serve(machine), fenced: { isFenced }, up: {
                    if let gate { for await _ in gate { break } }
                    return isUp
                }, end: { _ = ends.yield(machine) })
            })
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

    @Test func aLinkOfAnotherTeamIsEndedNotTaken() async {
        let world = World(), readiness = CloudSpareReadiness(world.dependencies())
        readiness.prime("vm_spare", team: "team_a")
        await readiness.settled("vm_spare")
        #expect(readiness.link(for: "vm_spare", team: "team_b") == nil)
        #expect(await firstValue(world.ended) == "vm_spare")
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
