import CmuxNextWakeups
import CoreFoundation
import Foundation
import Observation
import Testing

/// The input-response pass (p06-scheduler-206): while a key's input response is open, the
/// person's dirty observations and batch items apply in the key's own turn, before the commit;
/// automation's wait for their class; nothing is on the run loop while no response is open.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct InputResponsePassTests {
    @Test func aKeysModelChangeAppliesBeforeThatTurnsCommit() {
        let rig = Rig()
        let model = TitleModel()
        let view = TrackedTitle(model: model, causes: rig.causes, log: rig.log)
        #expect(view.shown == "", "the first value applies at once")
        // The key: its handler changes the model in the same turn, and the turn expects a frame.
        rig.budget.noteDiscreteInput(expectsFrame: true)
        rig.causes.with(.person) { model.title = "typed" }
        #expect(view.shown == "", "nothing applies inside the handler")
        rig.loop.turn()
        #expect(rig.log.events == ["apply typed", "commit"])
        #expect(view.shown == "typed")
        #expect(rig.pass.stats.observations == 1)
    }

    @Test func automationOnlyChangesAreNotAppliedInThePass() {
        let rig = Rig()
        let row = rig.observation("row")
        rig.budget.noteDiscreteInput(expectsFrame: true)
        row.change(to: "agent", cause: .automation)
        rig.loop.turn()
        #expect(rig.log.events == ["commit"], "it waits for the automation class")
        #expect(row.applied.isEmpty)
        #expect(rig.pass.stats.observations == 0)
        #expect(rig.causes.dirtyCount == 1)
    }

    @Test func automationThenPersonOnTheSamePropertyIsAppliedInThePass() {
        let rig = Rig()
        let row = rig.observation("row")
        rig.budget.noteDiscreteInput(expectsFrame: true)
        row.change(to: "agent", cause: .automation)
        // The person's change of the same value: the observation's first cause no longer decides.
        row.change(to: "person", cause: .person)
        rig.loop.turn()
        #expect(rig.log.events == ["apply row person", "commit"])
        #expect(row.applied == ["person"])
        #expect(rig.causes.dirtyCount == 0)
    }

    @Test func noObserverIsOnTheRunLoopWhileNoResponseIsOpen() {
        let rig = Rig()
        let row = rig.observation("row")
        #expect(!rig.pass.isInstalled)
        row.change(to: "person", cause: .person)
        let accepted = rig.pass.enqueue { rig.log.events.append("item") }
        #expect(!accepted, "outside a response a person item goes to userBlocking")
        #expect(!rig.pass.isInstalled)
        #expect(rig.loop.observerCount == 0)
        rig.loop.turn()
        #expect(rig.log.events == ["commit"], "its own class flushes it, not the pass")
        // A key that expects no frame opens no response.
        rig.budget.noteDiscreteInput(expectsFrame: false)
        #expect(!rig.pass.isInstalled)
        // A key that does: the observer is on the run loop until the response closes.
        rig.budget.noteDiscreteInput(expectsFrame: true)
        #expect(rig.loop.observerCount == 1)
        rig.loop.turn()
        #expect(rig.log.events == ["commit", "apply row person", "commit"])
        rig.closeResponse()
        #expect(!rig.pass.isInstalled)
        #expect(rig.loop.observerCount == 0)
        #expect(rig.pass.stats.installs == 1)
    }

    @Test func theCapClosingTheResponseRemovesTheObserver() {
        let rig = Rig()
        rig.budget.noteDiscreteInput(expectsFrame: true)
        #expect(rig.pass.isInstalled)
        rig.clock.advance(nanos: 100_000_000)
        // The budget sees the cap at its next check.
        _ = rig.budget.mayRun(.automation)
        #expect(!rig.pass.isInstalled)
        #expect(rig.loop.observerCount == 0)
    }

    @Test func personBatchItemsRunBeforeTheCommitInOrder() {
        let rig = Rig()
        rig.budget.noteDiscreteInput(expectsFrame: true)
        let first = rig.pass.enqueue { rig.log.events.append("patch 1") }
        let second = rig.pass.enqueue(owner: rig.budget.board.owner("SidebarRows")) {
            rig.log.events.append("patch 2")
            // An item queued by an item runs in the same pass.
            rig.pass.enqueue { rig.log.events.append("patch 3") }
        }
        #expect(first && second)
        rig.loop.turn()
        #expect(rig.log.events == ["patch 1", "patch 2", "patch 3", "commit"])
        #expect(rig.pass.stats.items == 3)
    }

    @Test func observationsApplyBeforeItems() {
        let rig = Rig()
        let row = rig.observation("row")
        rig.budget.noteDiscreteInput(expectsFrame: true)
        rig.pass.enqueue { rig.log.events.append("patch") }
        row.change(to: "person", cause: .person)
        rig.loop.turn()
        #expect(rig.log.events == ["apply row person", "patch", "commit"])
    }

    @Test func itemsAcceptedWhileOpenRunEvenIfTheResponseClosesFirst() {
        let rig = Rig()
        rig.budget.noteDiscreteInput(expectsFrame: true)
        rig.pass.enqueue { rig.log.events.append("patch") }
        rig.budget.noteUserBlockingCommit()
        #expect(rig.pass.isInstalled, "an accepted item is never dropped")
        rig.loop.turn()
        #expect(rig.log.events == ["patch", "commit"])
        #expect(!rig.pass.isInstalled)
    }

    @Test func aChangeAnApplyMakesWaitsForTheNextPass() {
        let rig = Rig()
        let first = rig.observation("a")
        let second = rig.observation("b")
        second.redirtiesOnApply = true
        rig.budget.noteDiscreteInput(expectsFrame: true)
        second.change(to: "2", cause: .person)
        first.change(to: "1", cause: .person)
        second.change(to: "3", cause: .person)
        rig.loop.turn()
        #expect(rig.log.events == ["apply b 3", "apply a 1", "commit"], "b keeps its first place and applies once")
        rig.loop.turn()
        #expect(rig.log.events.suffix(2) == ["apply b 3", "commit"])
    }

    @Test func aReleasedSourceIsDropped() {
        let rig = Rig()
        var other: FakeCauses? = FakeCauses()
        if let other { rig.pass.addSource(other) }
        other = nil
        rig.budget.noteDiscreteInput(expectsFrame: true)
        rig.loop.turn()
        #expect(rig.log.events == ["commit"])
    }

    /// The real main run loop: the pass runs before an observer at Core Animation's commit order
    /// that was added first (as Core Animation's is, at launch), and leaves the loop afterwards.
    @Test func onTheMainRunLoopThePassRunsBeforeTheCommitOrder() {
        let log = Log()
        let commit = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, 2_000_000
        ) { _, _ in
            // main-proof: the observer is added to the main run loop only (below).
            MainActor.assumeIsolated { log.events.append("commit") }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), commit, .commonModes)
        defer { CFRunLoopObserverInvalidate(commit) }
        let clock = PassClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let pass = InputResponsePass(budget: budget)
        #expect(!Self.mainRunLoopHasPassObserver())
        budget.noteDiscreteInput(expectsFrame: true)
        pass.enqueue { log.events.append("patch") }
        #expect(Self.mainRunLoopHasPassObserver())
        // The response closes before the turn ends: the accepted item still runs, then the
        // observer leaves the run loop.
        budget.noteUserBlockingCommit()
        Self.pollingTurn()
        #expect(log.events.prefix(2) == ["patch", "commit"], "\(log.events)")
        #expect(!pass.isInstalled)
        #expect(!Self.mainRunLoopHasPassObserver())
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

/// A budget on a moved clock, a fake run loop whose turns end in a commit, the cause state, and
/// the pass.
@MainActor
private final class Rig {
    let clock: PassClock
    let log: Log
    let causes: FakeCauses
    let budget: MainFrameBudget
    let loop: FakeCommitRunLoop
    let pass: InputResponsePass

    init() {
        let clock = PassClock()
        let log = Log()
        let causes = FakeCauses()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        let loop = FakeCommitRunLoop(log: log)
        let pass = InputResponsePass(budget: budget, runLoop: loop)
        pass.addSource(causes)
        self.clock = clock
        self.log = log
        self.causes = causes
        self.budget = budget
        self.loop = loop
        self.pass = pass
    }

    func observation(_ name: String) -> FakeObservation {
        FakeObservation(name: name, causes: causes, log: log)
    }

    /// The next link tick renders: the response closes.
    func closeResponse() {
        clock.advance(nanos: 16_666_667)
        budget.beginFrame(timestamp: 2, refreshInterval: 1.0 / 60)
        budget.noteTickRenderEnded()
        #expect(!budget.isInputResponseOpen)
    }
}

/// A run loop's commit stage: each turn calls the observers in order and logs `commit` where
/// Core Animation's observer (order 2,000,000) runs.
@MainActor
private final class FakeCommitRunLoop: InputResponseRunLoop {
    private let log: Log
    private var observers: [FakeObserver] = []

    init(log: Log) { self.log = log }

    var observerCount: Int {
        observers.removeAll { !$0.isValid }
        return observers.count
    }

    func observeBeforeCommit(order: CFIndex, _ handler: @escaping @MainActor () -> Void) -> any InputResponseObservation {
        let observer = FakeObserver(order: order, handler: handler)
        observers.append(observer)
        return observer
    }

    func turn() {
        // A snapshot, as CFRunLoop takes before a callout pass.
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

/// The cause state VisibleObservation's scheduler (p06-scheduler-025) keeps: the current cause, a
/// person-cause epoch a person's change moves, and the dirty observations in the order they became
/// dirty.
@MainActor
private final class FakeCauses: InputResponseSource {
    enum Cause { case person, automation }
    private(set) var current: Cause = .automation
    private(set) var personEpoch: UInt64 = 0
    private var dirty: [CausedObservation] = []

    var dirtyCount: Int { dirty.count }

    func with(_ cause: Cause, _ change: () -> Void) {
        let saved = current
        current = cause
        if cause == .person { personEpoch &+= 1 }
        change()
        current = saved
    }

    func register(_ observation: CausedObservation) {
        dirty.append(observation)
    }

    func applyPersonCaused() -> Int {
        let due = dirty.filter { $0.isPersonCaused(epoch: personEpoch) }
        dirty.removeAll { observation in due.contains { $0 === observation } }
        for observation in due { observation.applyNow() }
        return due.count
    }
}

/// A dirty-tracking observation: records its cause and the person epoch when it becomes dirty;
/// its flush is the person's when that cause was or the epoch moved since.
@MainActor
private class CausedObservation {
    let causes: FakeCauses
    private var dirtyCause: FakeCauses.Cause?
    private var epochAtDirty: UInt64 = 0

    init(causes: FakeCauses) {
        self.causes = causes
    }

    func isPersonCaused(epoch: UInt64) -> Bool {
        guard let dirtyCause else { return false }
        return dirtyCause == .person || epoch != epochAtDirty
    }

    func markDirty() {
        guard dirtyCause == nil else { return }
        dirtyCause = causes.current
        epochAtDirty = causes.personEpoch
        causes.register(self)
    }

    func applyNow() {
        dirtyCause = nil
        apply()
    }

    func apply() {}
}

/// A view's observation of one `@Observable` property through `withObservationTracking`.
@MainActor
private final class TrackedTitle: CausedObservation {
    private let model: TitleModel
    private let log: Log
    private(set) var shown = ""

    init(model: TitleModel, causes: FakeCauses, log: Log) {
        self.model = model
        self.log = log
        super.init(causes: causes)
        shown = track()
    }

    private func track() -> String {
        withObservationTracking { model.title } onChange: { [weak self] in
            // main-proof: the tests change the model on the main actor, and onChange runs
            // synchronously in that change's will-set.
            MainActor.assumeIsolated { self?.markDirty() }
        }
    }

    override func apply() {
        shown = track()
        log.events.append("apply \(shown)")
    }
}

@Observable @MainActor
private final class TitleModel {
    var title = ""
}

/// An observation fed by hand: `change(to:cause:)` stands for a model change with that cause.
@MainActor
private final class FakeObservation: CausedObservation {
    private let name: String
    private let log: Log
    private var value = ""
    private(set) var applied: [String] = []
    var redirtiesOnApply = false

    init(name: String, causes: FakeCauses, log: Log) {
        self.name = name
        self.log = log
        super.init(causes: causes)
    }

    func change(to newValue: String, cause: FakeCauses.Cause) {
        causes.with(cause) {
            value = newValue
            markDirty()
        }
    }

    override func apply() {
        applied.append(value)
        log.events.append("apply \(name) \(value)")
        if redirtiesOnApply { causes.with(.person) { markDirty() } }
    }
}

@MainActor
private final class Log {
    var events: [String] = []
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class PassClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(nanos: UInt64) { now += nanos }
}
