import CmuxNextWakeups
import CoreFoundation
import Foundation
import Observation
import Testing

/// The input-response pass: in a key's turn, the person's dirty observations
/// (``VisibleObservation`` through the scheduler's ``ObservationCauses``) and batch items apply
/// before the commit; automation's wait for their class; nothing is on the
/// run loop outside the person's turn. The keys follow the App's order (`InputDispatchContext`):
/// the dispatch begins, the handler changes the model, the input reports at the dispatch's end.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct InputResponsePassTests {
    @Test func aKeysModelChangeAppliesBeforeThatTurnsCommit() {
        let rig = Rig()
        let row = rig.observation("title")
        #expect(row.shown == "", "the first value applies at once")
        // The key: its handler changes the model, and its dispatch then reports a frame.
        rig.key { row.change(to: "typed", cause: .person) }
        #expect(row.shown == "", "nothing applies inside the handler")
        rig.loop.turn()
        #expect(rig.log.events == ["apply title typed", "commit"])
        #expect(row.shown == "typed")
        #expect(rig.pass.stats.observations == 1)
    }

    @Test func automationOnlyChangesAreNotAppliedInThePass() {
        let rig = Rig()
        let row = rig.observation("row")
        rig.key { row.change(to: "agent", cause: .automation) }
        rig.loop.turn()
        #expect(rig.log.events == ["commit"], "it waits for the automation class")
        #expect(row.applied.isEmpty)
        #expect(rig.pass.stats.observations == 0)
        #expect(rig.causes.personPendingCount == 0, "its flush stays in the automation class")
    }

    @Test func automationThenPersonOnTheSamePropertyIsAppliedInThePass() {
        let rig = Rig()
        let row = rig.observation("row")
        rig.key {
            row.change(to: "agent", cause: .automation)
            // The person's change of the same value: the observation's first cause no longer decides.
            row.change(to: "person", cause: .person)
        }
        rig.loop.turn()
        #expect(rig.log.events == ["apply row person", "commit"])
        #expect(row.applied == ["person"])
        #expect(rig.causes.personPendingCount == 0)
    }

    @Test func noObserverIsOnTheRunLoopOutsideThePersonsTurn() {
        let rig = Rig()
        let row = rig.observation("row")
        #expect(!rig.pass.isInstalled)
        row.change(to: "person", cause: .person)
        let accepted = rig.pass.enqueue { rig.log.events.append("item") }
        #expect(!accepted, "outside the person's turn a person item goes to userBlocking")
        #expect(!rig.pass.isInstalled)
        #expect(rig.loop.observerCount == 0)
        #expect(!rig.loop.hasQueuedWork)
        rig.loop.turn()
        #expect(rig.log.events == ["commit"], "its own class flushes it, not the pass")
        // A key that expects no frame opens no response: the observer leaves with its dispatch.
        rig.key(expectsFrame: false) { #expect(rig.loop.observerCount == 1) }
        #expect(!rig.pass.isInstalled)
        // A key that does: the observer is on the run loop until the response closes.
        rig.key {}
        #expect(rig.loop.observerCount == 1)
        rig.loop.turn()
        #expect(rig.log.events == ["commit", "apply row person", "commit"])
        rig.closeResponse()
        #expect(!rig.pass.isInstalled)
        #expect(rig.loop.observerCount == 0)
        #expect(rig.pass.stats.installs == 2)
    }

    @Test func theCapClosingTheResponseRemovesTheObserver() {
        let rig = Rig()
        rig.key {}
        #expect(rig.pass.isInstalled)
        rig.clock.advance(nanos: 100_000_000)
        // The budget sees the cap at its next check.
        _ = rig.budget.mayRun(.automation)
        #expect(!rig.pass.isInstalled)
        #expect(rig.loop.observerCount == 0)
    }

    /// The handler queues its item before its dispatch reports the input: the response is not
    /// open yet, and the item is still the person's.
    @Test func aHandlersItemIsAcceptedBeforeItsKeyReports() {
        let rig = Rig()
        var accepted = false
        rig.key {
            #expect(!rig.budget.isInputResponseOpen)
            accepted = rig.pass.enqueue { rig.log.events.append("patch") }
        }
        #expect(accepted, "the handler's item went to userBlocking")
        rig.loop.turn()
        #expect(rig.log.events == ["patch", "commit"])
        // A key whose turn then expects no frame still runs what its handler queued.
        rig.closeResponse()
        rig.key(expectsFrame: false) { accepted = rig.pass.enqueue { rig.log.events.append("late patch") } }
        #expect(accepted)
        rig.loop.turn()
        #expect(rig.log.events.suffix(2) == ["late patch", "commit"])
        #expect(!rig.pass.isInstalled)
    }

    @Test func personBatchItemsRunBeforeTheCommitInOrder() {
        let rig = Rig()
        var first = false
        var second = false
        rig.key {
            first = rig.pass.enqueue { rig.log.events.append("patch 1") }
            second = rig.pass.enqueue(owner: rig.budget.board.owner("SidebarRows")) {
                rig.log.events.append("patch 2")
                // An item queued by an item runs in the same pass.
                rig.pass.enqueue { rig.log.events.append("patch 3") }
            }
        }
        #expect(first && second)
        rig.loop.turn()
        #expect(rig.log.events == ["patch 1", "patch 2", "patch 3", "commit"])
        #expect(rig.pass.stats.items == 3)
    }

    @Test func observationsApplyBeforeItems() {
        let rig = Rig()
        let row = rig.observation("row")
        rig.key {
            rig.pass.enqueue { rig.log.events.append("patch") }
            row.change(to: "person", cause: .person)
        }
        rig.loop.turn()
        #expect(rig.log.events == ["apply row person", "patch", "commit"])
    }

    @Test func itemsAcceptedInTheTurnRunEvenIfTheResponseClosesFirst() {
        let rig = Rig()
        rig.key { rig.pass.enqueue { rig.log.events.append("patch") } }
        rig.budget.noteUserBlockingCommit()
        #expect(rig.pass.isInstalled, "an accepted item is never dropped")
        rig.loop.turn()
        #expect(rig.log.events == ["patch", "commit"])
        #expect(!rig.pass.isInstalled)
    }

    /// An item accepted after this turn's pass ran (AppKit's display cycle, a later observer), in
    /// the stage that also closes the response: the pass makes the next turn come for it.
    @Test func anItemAcceptedAfterThisTurnsPassRunsOnTheNextTurnWithoutAnotherInput() {
        let rig = Rig()
        rig.key {}
        var lateOnce = true
        let late = rig.loop.observeBeforeCommit(order: InputResponsePass.order + 1) {
            guard lateOnce else { return }
            lateOnce = false
            #expect(rig.pass.enqueue { rig.log.events.append("late") })
            rig.closeResponse()
        }
        rig.loop.turn()
        late.invalidate()
        #expect(rig.log.events == ["commit"])
        #expect(rig.loop.hasQueuedWork, "nothing wakes the run loop for the accepted item")
        rig.loop.turn()
        #expect(rig.log.events == ["commit", "late", "commit"])
        #expect(!rig.pass.isInstalled)
    }

    /// A click whose tracking loop runs nested in its dispatch: the click reports from an observer
    /// at the first wait of that loop, ahead of the pass in the same stage. The pass was on the run
    /// loop since the dispatch began, so it is in that stage's snapshot.
    @Test func aResponseOpenedInTheCommitStageAppliesBeforeThatCommit() {
        let rig = Rig()
        let row = rig.observation("button")
        rig.budget.noteDiscreteDispatch(began: true)
        row.change(to: "pressed", cause: .person)
        let nestedWait = rig.loop.observeBeforeCommit(order: CFIndex.min) {
            rig.budget.noteDiscreteInput(expectsFrame: true)
        }
        rig.loop.turn()
        nestedWait.invalidate()
        rig.budget.noteDiscreteDispatch(began: false)
        #expect(rig.log.events == ["apply button pressed", "commit"])
    }

    @Test func personChangesApplyOnceEachInTheOrderTheyBecameThePersons() {
        let rig = Rig()
        let first = rig.observation("a")
        let second = rig.observation("b")
        rig.key {
            second.change(to: "2", cause: .person)
            first.change(to: "1", cause: .person)
            second.change(to: "3", cause: .person)
        }
        rig.loop.turn()
        #expect(rig.log.events == ["apply b 3", "apply a 1", "commit"], "b keeps its first place and applies once")
        rig.loop.turn()
        #expect(rig.log.events.suffix(2) == ["commit", "commit"], "nothing is left for the next pass")
    }

    @Test func aReleasedSourceIsDropped() {
        let rig = Rig()
        var other: LoggingSource? = LoggingSource(log: rig.log)
        other?.pending = ["released"]
        if let other { rig.pass.addSource(other) }
        other = nil
        rig.key {}
        rig.loop.turn()
        #expect(rig.log.events == ["commit"])
    }

    /// The real main run loop: the pass runs before an observer at Core Animation's commit order
    /// that was added first (as Core Animation's is, at launch), and leaves the loop afterwards.
    @Test func onTheMainRunLoopThePassRunsBeforeTheCommitOrder() {
        let log = Log()
        let commit = Self.addCommitObserver(log)
        defer { CFRunLoopObserverInvalidate(commit) }
        let clock = PassClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let pass = InputResponsePass(budget: budget)
        #expect(!Self.mainRunLoopHasPassObserver())
        budget.noteDiscreteDispatch(began: true)
        #expect(Self.mainRunLoopHasPassObserver())
        pass.enqueue { log.events.append("patch") }
        budget.noteDiscreteInput(expectsFrame: true)
        budget.noteDiscreteDispatch(began: false)
        // The response closes before the turn ends: the accepted item still runs, then the
        // observer leaves the run loop.
        budget.noteUserBlockingCommit()
        Self.pollingTurn()
        #expect(log.events.prefix(2) == ["patch", "commit"], "\(log.events)")
        #expect(!pass.isInstalled)
        #expect(!Self.mainRunLoopHasPassObserver())
    }

    /// The real main run loop, a nested loop's first wait: an observer at `CFIndex.min` of the
    /// commit stage reports the click (as `InputDispatchContext` does), and the person's apply
    /// still comes before the order-2,000,000 commit of that same pass.
    @Test func onTheMainRunLoopAResponseOpenedInTheCommitStageAppliesBeforeThatCommit() {
        let log = Log()
        let commit = Self.addCommitObserver(log)
        defer { CFRunLoopObserverInvalidate(commit) }
        let clock = PassClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let source = LoggingSource(log: log)
        let pass = InputResponsePass(budget: budget)
        pass.addSource(source)
        budget.noteDiscreteDispatch(began: true)
        source.pending = ["pressed"]
        let report = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, false, CFIndex.min
        ) { _, _ in
            // main-proof: the observer is added to the main run loop only (below).
            MainActor.assumeIsolated { budget.noteDiscreteInput(expectsFrame: true) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), report, .commonModes)
        defer { CFRunLoopObserverInvalidate(report) }
        Self.pollingTurn()
        budget.noteDiscreteDispatch(began: false)
        #expect(log.events.prefix(2) == ["apply pressed", "commit"], "\(log.events)")
        #expect(pass.stats.observations == 1)
    }

    /// An observer at Core Animation's commit order that logs `commit`.
    private static func addCommitObserver(_ log: Log) -> CFRunLoopObserver? {
        let commit = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, 2_000_000
        ) { _, _ in
            // main-proof: the observer is added to the main run loop only (below).
            MainActor.assumeIsolated { log.events.append("commit") }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), commit, .commonModes)
        return commit
    }

    /// One main run-loop turn that polls and exits without waiting (only the exit stage fires);
    /// a far-future timer keeps the default mode non-empty for the turn.
    private static func pollingTurn() {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
        CFRunLoopTimerInvalidate(timer)
    }

    private static func mainRunLoopHasPassObserver() -> Bool {
        (CFCopyDescription(CFRunLoopGetMain()) as String).contains("order = \(InputResponsePass.order),")
    }
}

/// A scheduler whose budget is on a moved clock (its link never fires, so a posted flush waits),
/// a visible node, a fake run loop whose turns end in a commit, and the pass, whose source is the
/// scheduler's production ``ObservationCauses``.
@MainActor
private final class Rig {
    let clock: PassClock
    let log: Log
    let work: MainWorkScheduler
    let node: VisibilityNode
    let loop: FakeCommitRunLoop
    let pass: InputResponsePass
    private let keeper: FrameClient

    var budget: MainFrameBudget { work.budget }
    var causes: ObservationCauses { work.causes }

    init() {
        let clock = PassClock()
        let log = Log()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let work = MainWorkScheduler.testing(budget: budget) { _ in PassFrameLink() }
        // Keeps the link up, so posts wait for frames the test never fires.
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        let loop = FakeCommitRunLoop(log: log)
        let pass = InputResponsePass(budget: budget, runLoop: loop)
        pass.addSource(work.causes)
        self.clock = clock
        self.log = log
        self.work = work
        self.keeper = keeper
        node = VisibilityNode(root: "window", own: .visible)
        self.loop = loop
        self.pass = pass
    }

    func observation(_ name: String) -> Row {
        Row(name: name, rig: self)
    }

    /// A discrete input in the App's order (`InputDispatchContext.dispatching`): the dispatch
    /// begins, the handler runs, the input reports, the dispatch ends.
    func key(expectsFrame: Bool = true, _ handler: () -> Void) {
        budget.noteDiscreteDispatch(began: true)
        handler()
        budget.noteDiscreteInput(expectsFrame: expectsFrame)
        budget.noteDiscreteDispatch(began: false)
    }

    /// The next link tick renders: the response closes.
    func closeResponse() {
        clock.advance(nanos: 16_666_667)
        budget.beginFrame(timestamp: CFTimeInterval(clock.now), refreshInterval: 1.0 / 60)
        budget.noteTickRenderEnded()
        #expect(!budget.isInputResponseOpen)
    }
}

/// A run loop turn: the queued blocks run, then the commit stage calls its observers in order
/// (from a snapshot taken before the first callout, as CFRunLoop does) and logs `commit` where
/// Core Animation's observer (order 2,000,000) runs.
@MainActor
private final class FakeCommitRunLoop: InputResponseRunLoop {
    private let log: Log
    private var observers: [FakeObserver] = []
    private var blocks: [@MainActor () -> Void] = []

    init(log: Log) { self.log = log }

    var observerCount: Int {
        observers.removeAll { !$0.isValid }
        return observers.count
    }

    /// Work queued with ``perform(_:)``: the run loop is woken for a turn.
    var hasQueuedWork: Bool { !blocks.isEmpty }

    func observeBeforeCommit(order: CFIndex, _ handler: @escaping @MainActor () -> Void) -> any InputResponseObservation {
        let observer = FakeObserver(order: order, handler: handler)
        observers.append(observer)
        return observer
    }

    func perform(_ work: @escaping @MainActor () -> Void) {
        blocks.append(work)
    }

    func turn() {
        let queued = blocks
        blocks.removeAll()
        for block in queued { block() }
        let pass = observers.filter(\.isValid).sorted { $0.order < $1.order }
        var committed = false
        for observer in pass {
            if !committed, observer.order >= 2_000_000 {
                log.events.append("commit")
                committed = true
            }
            if observer.isValid { observer.handler() }
        }
        if !committed { log.events.append("commit") }
    }
}

private final class FakeObserver: InputResponseObservation {
    let order: CFIndex
    let handler: @MainActor () -> Void
    private(set) var isValid = true

    init(order: CFIndex, handler: @escaping @MainActor () -> Void) {
        self.order = order
        self.handler = handler
    }

    func invalidate() { isValid = false }
}

@Observable @MainActor
private final class RowModel {
    var value = ""
}

/// A view's ``VisibleObservation`` of one `@Observable` property under the rig's visible node;
/// `change(to:cause:)` changes the property with that cause in effect.
@MainActor
private final class Row {
    private let name: String
    private let model = RowModel()
    private let causes: ObservationCauses
    private let log: Log
    private var watch: VisibleObservation<String>?
    private(set) var shown = ""
    /// The values applied after the first.
    private(set) var applied: [String] = []

    init(name: String, rig: Rig) {
        self.name = name
        causes = rig.causes
        log = rig.log
        let model = self.model
        watch = VisibleObservation(rig.node, owner: "test.\(name)", on: rig.work) {
            model.value
        } apply: { [weak self] value in
            self?.show(value)
        }
    }

    func change(to newValue: String, cause: ObservationCause) {
        causes.withCause(cause) { model.value = newValue }
    }

    private func show(_ value: String) {
        let first = watch == nil
        shown = value
        guard !first else { return }
        applied.append(value)
        log.events.append("apply \(name) \(value)")
    }
}

/// A source whose pending names apply (and log) when the pass asks.
@MainActor
private final class LoggingSource: InputResponseSource {
    var pending: [String] = []
    private let log: Log

    init(log: Log) { self.log = log }

    func applyPersonCaused() -> Int {
        let due = pending
        pending.removeAll()
        log.events += due.map { "apply \($0)" }
        return due.count
    }
}

@MainActor
private final class PassFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

@MainActor
private final class Log {
    var events: [String] = []
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class PassClock {
    private(set) var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(nanos: UInt64) { now += nanos }
}
