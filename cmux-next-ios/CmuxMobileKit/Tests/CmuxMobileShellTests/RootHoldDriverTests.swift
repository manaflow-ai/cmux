import Foundation
import Testing
@testable import CmuxMobileShell

/// #56696 F1 and F2, the sequencing around `RootHold.step`: when the enforcer reads the stack,
/// follows a transition, rechecks and releases. Driven by a fake stack, clock and main queue.
///
/// Review on 3f1e4cb found two gaps the pure rule could not show: a release decided on one turn
/// and run on the next against a stack that had changed in between, and a transition UIKit
/// declines to report the end of, asked again every turn with the bound's clock reset each time.
@MainActor
struct RootHoldDriverTests {
    @Test func aReleaseDecidedBeforeANewTransitionDecidesAgain() {
        let stack = FakeStack(transition: Token(), rootRequested: true, depth: 2)
        let driver = stack.driver()
        driver.follow()
        #expect(stack.reports == [true])
        // The pop finishes: the next turn reads a settled root and decides to release.
        stack.reading = RootHoldReading(transition: nil, rootRequested: true, depth: 1)
        stack.finish()
        stack.turn()
        // Before the release runs, a page is pushed (a link, a notification tap).
        let push = Token()
        stack.reading = RootHoldReading(transition: ObjectIdentifier(push), rootRequested: false, depth: 1)
        stack.run(for: 0)
        #expect(!stack.reports.contains(false), "no release against the stack it was decided on")
        #expect(driver.following)
        // The push finishes: only then does the hold end.
        stack.reading = RootHoldReading(transition: nil, rootRequested: false, depth: 2)
        stack.finish()
        stack.run(for: 0)
        #expect(stack.reports.last == false)
        #expect(stack.reports.filter { !$0 }.count == 1)
    }

    @Test func aDeclinedTransitionIsRecheckedOnTheTimerAndBounded() {
        let stack = FakeStack(transition: Token(), rootRequested: true, depth: 2, accepts: false)
        let driver = stack.driver()
        driver.follow()
        #expect(stack.reports == [true])
        #expect(stack.registrations == 1)
        #expect(stack.queue.allSatisfy { $0.at >= stack.clock.addingTimeInterval(RootHold.recheck) },
                "a decline is not asked again on the next turn")
        // Layouts and gestures keep calling in; the declined transition is not asked again,
        // and its clock runs from the first decline.
        for _ in 0..<9 {
            driver.settle()
            driver.follow()
            stack.run(for: 0.1)
        }
        #expect(stack.registrations == 1)
        #expect(stack.reports == [true])
        stack.run(for: 0.2)
        #expect(stack.reports == [true, false], "released at the bound")
        #expect(stack.bounds == 1)
        // Still running: it stays declined, so the chrome is not held for another bound.
        for _ in 0..<20 {
            driver.settle()
            driver.follow()
            stack.run(for: 0.1)
        }
        #expect(stack.registrations == 1)
        #expect(!stack.reports.dropFirst().contains(true))
        #expect(stack.bounds == 1, "logged once")
    }

    @Test func aNewTransitionAfterADeclinedOneIsFollowed() {
        let stack = FakeStack(transition: Token(), rootRequested: true, depth: 2, accepts: false)
        let driver = stack.driver()
        driver.follow()
        stack.run(for: 0.1)
        let pop = Token()
        stack.reading.transition = ObjectIdentifier(pop)
        stack.accepts = true
        stack.run(for: 0.1)
        #expect(stack.registrations == 2)
        #expect(driver.following)
        stack.run(for: 5)
        #expect(!stack.reports.contains(false), "a transition that reports its end is never released at the bound")
    }

    @Test func aSlowOrInteractiveTransitionHoldsUntilItEnds() {
        let stack = FakeStack(transition: Token(), rootRequested: true, depth: 2)
        let driver = stack.driver()
        driver.follow()
        for _ in 0..<100 {
            driver.settle()
            driver.follow()
            stack.run(for: 0.6)
        }
        #expect(stack.reports == [true], "60 s of a running transition: no release")
        #expect(stack.bounds == 0)
        stack.reading = RootHoldReading(transition: nil, rootRequested: true, depth: 1)
        stack.finish()
        stack.run(for: 0)
        #expect(stack.reports == [true, false])
    }

    @Test func aCancelledSwipeReleasesUnderThePageItRestored() {
        let stack = FakeStack(transition: Token(), rootRequested: false, depth: 2)
        let driver = stack.driver()
        driver.follow()
        stack.reading = RootHoldReading(transition: nil, rootRequested: false, depth: 2)
        stack.finish()
        stack.run(for: 0)
        #expect(stack.reports == [true, false])
    }

    @Test func anEmptiedPathWaitsForTheNonanimatedPop() {
        let stack = FakeStack(transition: nil, rootRequested: true, depth: 2)
        let driver = stack.driver()
        driver.settle()
        stack.run(for: 0.3)
        #expect(stack.reports.isEmpty, "waiting on the pop")
        stack.reading.depth = 1
        stack.run(for: RootHold.recheck)
        #expect(stack.reports == [false])
        #expect(stack.bounds == 0)
    }

    @Test func aPopThatNeverComesIsReleasedAtTheBound() {
        let stack = FakeStack(transition: nil, rootRequested: true, depth: 2)
        let driver = stack.driver()
        driver.settle()
        stack.run(for: RootHold.bound * 0.9)
        #expect(stack.reports.isEmpty)
        stack.run(for: RootHold.bound * 0.2)
        #expect(stack.reports == [false])
        #expect(stack.bounds == 1)
    }
}

private final class Token {}

@MainActor
private final class FakeStack {
    var reading: RootHoldReading
    var accepts: Bool
    var clock = Date(timeIntervalSince1970: 0)
    var queue: [(at: Date, work: @MainActor () -> Void)] = []
    var reports: [Bool] = []
    var registrations = 0
    var bounds = 0
    private var completion: (@MainActor () -> Void)?
    private var tokens: [Token] = []

    init(transition: Token?, rootRequested: Bool, depth: Int?, accepts: Bool = true) {
        tokens = transition.map { [$0] } ?? []
        reading = RootHoldReading(transition: transition.map { ObjectIdentifier($0) }, rootRequested: rootRequested, depth: depth)
        self.accepts = accepts
    }

    func driver() -> RootHoldDriver {
        let driver = RootHoldDriver(
            read: { [unowned self] in reading },
            register: { [unowned self] done in
                registrations += 1
                if accepts { completion = done }
                return accepts
            },
            after: { [unowned self] delay, work in queue.append((clock.addingTimeInterval(delay), work)) },
            now: { [unowned self] in clock }
        )
        driver.moving = { [unowned self] in reports.append($0) }
        driver.onBound = { [unowned self] _ in bounds += 1 }
        return driver
    }

    /// The followed transition ends (UIKit calls its completion).
    func finish() {
        let done = completion
        completion = nil
        done?()
    }

    /// Runs the earliest queued work, advancing the clock to it.
    func turn() {
        guard let index = queue.indices.min(by: { queue[$0].at < queue[$1].at }) else { return }
        let item = queue.remove(at: index)
        if item.at > clock { clock = item.at }
        item.work()
    }

    /// Runs every work due within `seconds`, then leaves the clock at its end.
    func run(for seconds: TimeInterval) {
        let end = clock.addingTimeInterval(seconds)
        while let next = queue.map(\.at).min(), next <= end { turn() }
        clock = end
    }
}
