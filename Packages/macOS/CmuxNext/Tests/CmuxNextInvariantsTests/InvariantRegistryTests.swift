#if DEBUG || CMUX_BENCH_HOOKS
import CoreFoundation
@testable import CmuxNextInvariants
import Testing

/// The one invariant framework (plans/cmux-next/invariants-DESIGN.md): a rule broken after an action or after a
/// turn is in the ledger at that turn's commit, named by what ran; a signature is reported once until it clears;
/// a level precondition skips the rule; an idle turn runs nothing.
@MainActor @Suite(.serialized)
struct InvariantRegistryTests {
    /// One main run-loop turn that polls and exits without waiting, so the turn observer's `exit` call runs.
    private func committedTurn() {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
        CFRunLoopTimerInvalidate(timer)
    }

    @Test func aRuleBrokenByAnActionIsReportedAtThatTurnsCommitAndNamesTheAction() {
        let clock = InvariantTestClock()
        let registry = clock.registry()
        let world = InvariantTestWorld()
        registry.declare(world.stripRule(points: .afterAction))
        let observer = InvariantTurnObserver(registry: registry)
        defer { observer.invalidate() }
        world.strips["p1"] = .init(pane: "p1", shown: 1, held: 2)
        registry.noteAction("tab.close", origin: "key")
        committedTurn()
        let violations = registry.ledger.since(0).violations
        #expect(violations.map(\.id) == ["T1"], "the action's turn ended with the rule broken and nothing reported")
        #expect(violations.first?.subject == .pane("p1"))
        #expect(violations.first?.trigger.kind == .action)
        #expect(violations.first?.trigger.actions.map(\.id) == ["tab.close"])
        #expect(violations.first?.state == nil, "the turn does not encode the state: the report's files lane does")
    }

    @Test func aRuleBrokenInATurnThatTouchedItsKeyIsReportedAtThatTurnsCommit() {
        let clock = InvariantTestClock()
        let registry = clock.registry()
        let world = InvariantTestWorld()
        registry.declare(world.stripRule(points: .afterTurn))
        let observer = InvariantTurnObserver(registry: registry)
        defer { observer.invalidate() }
        world.strips["p1"] = .init(pane: "p1", shown: 3, held: 2)
        world.strips["p2"] = .init(pane: "p2", shown: 0, held: 1)
        registry.touch(.tabs, .pane("p1"))
        committedTurn()
        let violations = registry.ledger.since(0).violations
        #expect(violations.map(\.subject) == [.pane("p1")], "only the dirty subject is checked after a turn")
        #expect(violations.first?.trigger.kind == .turn)
        #expect(registry.turnsChecked == 1)
    }

    @Test func anIdleTurnRunsNoRule() {
        let clock = InvariantTestClock()
        let registry = clock.registry()
        let world = InvariantTestWorld()
        registry.declare(world.stripRule())
        let observer = InvariantTurnObserver(registry: registry)
        defer { observer.invalidate() }
        committedTurn()
        committedTurn()
        #expect(world.reads == 0)
        #expect(registry.turnsChecked == 0)
    }

    @Test func aSignatureIsReportedOnceUntilItClearsAndThenAgain() {
        let clock = InvariantTestClock()
        let registry = clock.registry()
        let world = InvariantTestWorld()
        registry.declare(world.stripRule())
        world.strips["p1"] = .init(pane: "p1", shown: 1, held: 2)
        for _ in 0..<3 {
            registry.touch(.tabs, .pane("p1"))
            registry.runTurn()
        }
        #expect(registry.ledger.lastSeq == 1, "a broken rule is reported once, not every turn")
        world.strips["p1"] = .init(pane: "p1", shown: 2, held: 2)
        registry.touch(.tabs, .pane("p1"))
        registry.runTurn()
        world.strips["p1"] = .init(pane: "p1", shown: 2, held: 3)
        registry.touch(.tabs, .pane("p1"))
        registry.runTurn()
        #expect(registry.ledger.lastSeq == 2, "broken again after it cleared: a new report")
        #expect(registry.stats(of: "T1")?.violations == 2)
    }

    @Test func aLevelPreconditionSkipsTheRuleAndDoesNotClearIt() {
        let clock = InvariantTestClock()
        let registry = clock.registry()
        let world = InvariantTestWorld()
        registry.declare(world.stripRule())
        world.strips["p1"] = .init(pane: "p1", shown: 1, held: 2)
        world.dragInFlight = true
        registry.touch(.tabs, .pane("p1"))
        registry.runTurn()
        #expect(registry.ledger.lastSeq == 0, "the rule does not apply while the drag is in flight")
        world.dragInFlight = false
        registry.touch(.tabs, .pane("p1"))
        registry.runTurn()
        #expect(registry.ledger.lastSeq == 1)
    }

    @Test func aTurnThatChecksAnotherSubjectNeitherClearsNorReportsAgain() {
        let clock = InvariantTestClock()
        let registry = clock.registry()
        let world = InvariantTestWorld()
        registry.declare(world.stripRule())
        world.strips["p1"] = .init(pane: "p1", shown: 1, held: 2)
        world.strips["p2"] = .init(pane: "p2", shown: 0, held: 1)
        for pane in ["p1", "p2", "p1"] {
            registry.touch(.tabs, .pane(pane))
            registry.runTurn()
        }
        let reported = registry.ledger.since(0).violations.map(\.subject)
        #expect(reported == [.pane("p1"), .pane("p2")], "p1 stays reported while a turn checks only p2: \(reported)")
    }

    @Test func aTurnThatTouchesACleanSubjectKeepsTheOthersReported() {
        let clock = InvariantTestClock()
        let registry = clock.registry()
        let world = InvariantTestWorld()
        registry.declare(world.stripRule())
        world.strips["p1"] = .init(pane: "p1", shown: 1, held: 2)
        world.strips["p3"] = .init(pane: "p3", shown: 1, held: 1)
        registry.touch(.tabs, .pane("p1"))
        registry.runTurn()
        registry.touch(.tabs, .pane("p3"))
        registry.runTurn()
        registry.touch(.tabs, .pane("p1"))
        registry.runTurn()
        #expect(registry.ledger.lastSeq == 1, "a clean p3 does not clear p1's report")
    }

    @Test func aSkippedSubjectKeepsItsReportUntilARunChecksIt() {
        let clock = InvariantTestClock()
        let registry = clock.registry()
        let world = InvariantTestWorld()
        registry.declare(world.pageRule())
        let turn = {
            registry.touch(.paneFrame, .window("w1"))
            registry.runTurn()
        }
        turn()
        world.resizing = true
        turn()
        world.resizing = false
        turn()
        #expect(registry.ledger.lastSeq == 1, "a live resize that skips the window does not clear its report")
        world.pageOff = false
        turn()
        world.pageOff = true
        turn()
        #expect(registry.ledger.lastSeq == 2, "checked clean, then broken again: a new report")
    }

    @Test func aLivenessRuleReportsAtItsLimitWithNoInputToRunIt() {
        let clock = InvariantTestClock()
        let registry = clock.registry()
        let world = InvariantTestWorld()
        registry.declare(world.landsRule(limit: .seconds(2)))
        world.pending["w1"] = clock.now
        registry.touch(.focus, .window("w1"))
        registry.runTurn()
        #expect(registry.ledger.lastSeq == 0)
        #expect(clock.scheduled?.delay == .seconds(2), "one deadline at the earliest limit")
        clock.fire()
        registry.runTurn()
        let violations = registry.ledger.since(0).violations
        #expect(violations.map(\.id) == ["L1"])
        #expect(violations.first?.trigger.kind == .liveness)
    }

    @Test func aCheckOnDemandRunsEveryRuleOnEverySubject() {
        let clock = InvariantTestClock()
        let registry = clock.registry(mode: .off)
        let world = InvariantTestWorld()
        registry.declare(world.stripRule())
        world.strips["p1"] = .init(pane: "p1", shown: 1, held: 2)
        world.strips["p2"] = .init(pane: "p2", shown: 0, held: 1)
        registry.touch(.tabs, .pane("p1"))
        registry.runTurn()
        #expect(world.reads == 0, "an unarmed registry runs nothing by itself")
        let found = registry.checkNow()
        #expect(found.map(\.finding.subject) == [.pane("p1"), .pane("p2")])
        #expect(registry.ledger.since(0).violations.allSatisfy { $0.trigger.kind == .check })
    }

    @Test func aSlowRuleIsItsOwnViolation() {
        let clock = InvariantTestClock()
        let registry = clock.registry()
        registry.declare(InvariantRule(id: "S1", statement: "slow", owner: "Tests", reads: [.tabs], points: .afterTurn,
                                       cost: .walk, read: { (_: InvariantPass) -> [Int]? in
                                           clock.now += .milliseconds(1)
                                           return [0]
                                       }, check: { (_: [Int]) -> [InvariantFinding] in [] }))
        for _ in 0..<Int(InvariantRegistry.costMinimumRuns) {
            registry.touch(.tabs, .app)
            registry.runTurn()
        }
        #expect(registry.ledger.since(0).violations.map(\.id) == ["INV-COST@S1"])
    }

    @Test func aSlowSharedReadIsThePassesViolation() {
        let clock = InvariantTestClock()
        let registry = clock.registry()
        registry.declare(InvariantRule(id: "S2", statement: "reads a slow memo", owner: "Tests", reads: [.tabs], points: .afterTurn,
                                       cost: .walk, read: { (pass: InvariantPass) -> [Int]? in
                                           pass.memo("slow") { () -> [Int] in
                                               clock.now += .milliseconds(2)
                                               return [0]
                                           }
                                       }, check: { (_: [Int]) -> [InvariantFinding] in [] }))
        for _ in 0..<Int(InvariantRegistry.costMinimumRuns) {
            registry.touch(.tabs, .app)
            registry.runTurn()
        }
        #expect(registry.ledger.since(0).violations.map(\.id) == ["INV-COST@pass"],
                "the shared walk is charged to no rule, so the pass's own budget reports it")
    }

    @Test func aPassHandsItsNewViolationsOverAsOneBatchWithTheirStates() throws {
        let clock = InvariantTestClock()
        let registry = clock.registry()
        let world = InvariantTestWorld()
        registry.declare(world.stripRule())
        var batches: [[InvariantRegistry.NewViolation]] = []
        registry.onReports = { batches.append($0) }
        world.strips["p1"] = .init(pane: "p1", shown: 1, held: 2)
        world.strips["p2"] = .init(pane: "p2", shown: 0, held: 1)
        registry.noteAction("tab.move", origin: "cli")
        registry.runTurn()
        #expect(batches.count == 1, "one report for the pass, not one per violation")
        #expect(batches.first?.map(\.violation.subject) == [.pane("p1"), .pane("p2")])
        #expect(registry.ledger.since(0).violations.allSatisfy { $0.state == nil && $0.report == nil },
                "the turn encodes no state and names no report file before it exists")
        let state = try #require(batches.first?.first?.state())
        #expect(String(decoding: state, as: UTF8.self).contains("\"pane\":\"p1\""), "the state is encoded on demand")
    }

    @Test func aCallSiteFailureGoesToTheSameLedger() {
        let clock = InvariantTestClock()
        let registry = clock.registry()
        registry.noteAction("pane.split", origin: "cli")
        InvariantProbe(registry: registry).fail("M1", .machine("local"), "mirror written outside apply")
        let violation = registry.ledger.since(0).violations.first
        #expect(violation?.id == "M1")
        #expect(violation?.trigger.kind == .inline)
        #expect(violation?.trigger.actions.map(\.id) == ["pane.split"])
    }

    @Test func anUnarmedRegistryStillListsWhatACallSiteCheckCaught() {
        let clock = InvariantTestClock()
        let registry = clock.registry(mode: .off)
        registry.noteAction("pane.split", origin: "key")
        InvariantProbe(registry: registry).fail("M1", .machine("local"), "mirror written outside apply")
        #expect(registry.ledger.since(0).violations.map(\.id) == ["M1"], "a bench build's M1 is not dropped")
    }

    @Test func theRingKeepsItsLastEntriesAndNamesThemBySequence() {
        let clock = InvariantTestClock()
        let registry = clock.registry()
        let total = InvariantLedger.capacity * 2 + 3
        for index in 0..<total {
            registry.fail("M1", .pane("p\(index)"), "x")
        }
        let kept = registry.ledger.since(0).violations
        #expect(kept.count == InvariantLedger.capacity)
        #expect(kept.first?.seq == UInt64(total - InvariantLedger.capacity + 1))
        #expect(kept.last?.seq == UInt64(total))
        #expect(kept.map(\.seq) == Array(kept.first!.seq...UInt64(total)), "oldest first, in order across the wrap")
        registry.ledger.annotate(UInt64(total), report: "/r.json")
        #expect(registry.ledger.since(UInt64(total - 1)).violations.first?.report == "/r.json")
    }

    @Test func aReaderBehindTheRingIsToldItMissedViolations() {
        let clock = InvariantTestClock()
        let registry = clock.registry()
        for index in 0..<(InvariantLedger.capacity + 2) {
            registry.fail("M1", .pane("p\(index)"), "x")
        }
        #expect(registry.ledger.since(0).dropped)
        #expect(!registry.ledger.since(2).dropped)
        #expect(registry.ledger.since(registry.ledger.lastSeq).violations.isEmpty)
    }
}
#endif
