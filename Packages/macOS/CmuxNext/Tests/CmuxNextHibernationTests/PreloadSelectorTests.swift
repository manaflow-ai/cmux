import CmuxNextCompat
import CmuxNextHibernation
import Testing

/// ``PreloadSelector`` (p13-webui.md section 3.D, task 042): Chrome's one-preload rules and their
/// properties over a fixed pseudo-random corpus: at most one page, never under pressure, never before
/// the first paint or its 3 s deadline plus 750 ms of quiet input, a held page is never replaced, a
/// wait names the moment the decision changes (its deadline, or the first paint when that can come
/// first), and the page does not depend on the dictionary's order.
@Suite struct PreloadSelectorTests {
    typealias Facts = PreloadSelector.Facts
    typealias Page = PreloadSelector.Page

    let selector = PreloadSelector()

    // MARK: Examples

    @Test func newTabPreloadsAfterTheFirstPaintAndQuietInput() {
        #expect(selector.decide(Facts(now: 1, firstPaintAt: 0.5)) == .later(at: 1.25, orFirstPaint: false))
        #expect(selector.decide(Facts(now: 1.25, firstPaintAt: 0.5)) == .preload(.newTab))
        #expect(selector.decide(Facts(now: 2, firstPaintAt: 0.5, lastInputAt: 1.5)) == .later(at: 2.25, orFirstPaint: false),
                "a preload started in the person's typing")
    }

    /// The adapter decides at launch, before any paint: the wait must wake on the paint, or every
    /// preload waits for the 3 s deadline.
    @Test func aWaitBeforeThePaintWakesOnThePaint() {
        #expect(selector.decide(Facts(now: 0)) == .later(at: 3.75, orFirstPaint: true))
        #expect(selector.decide(Facts(now: 0.5, firstPaintAt: 0.5)) == .later(at: 1.25, orFirstPaint: false))
        #expect(selector.decide(Facts(now: 1.25, firstPaintAt: 0.5)) == .preload(.newTab), "the paint did not open the gate")
        #expect(selector.decide(Facts(now: 3.2, lastInputAt: 3.1)) == .later(at: 3.85, orFirstPaint: false),
                "woke on a paint after its deadline had passed")
    }

    @Test func noFirstPaintWaitsForTheThreeSecondDeadline() {
        #expect(selector.decide(Facts(now: 2)) == .later(at: 3.75, orFirstPaint: true))
        #expect(selector.decide(Facts(now: 3.75)) == .preload(.newTab))
        #expect(selector.decide(Facts(now: 3.75, firstPaintAt: 3.5)) == .preload(.newTab), "a late paint delayed the deadline")
    }

    @Test func pressureDropsTheHeldPageAndStartsNone() {
        for pressure in [MemoryPressureLevel.warning, .critical] {
            #expect(selector.decide(Facts(now: 10, firstPaintAt: 1, pressure: pressure, held: .newTab)) == .drop)
            #expect(selector.decide(Facts(now: 10, firstPaintAt: 1, pressure: pressure)) == .blocked)
        }
    }

    @Test func aHeldPageIsKeptEvenWhenAnotherWasOpenedSince() {
        let facts = Facts(now: 10, firstPaintAt: 1, lastOpened: [.settings: 9], held: .newTab)
        #expect(selector.decide(facts) == .keep, "two pages took turns evicting each other")
    }

    @Test func aRecentlyOpenedClosedPageTakesNewTabsPlace() {
        let recent = Facts(now: 100, firstPaintAt: 1, lastOpened: [.settings: 50, .history: 80, .newTab: 99])
        #expect(selector.decide(recent) == .preload(.history))

        var stillOpen = recent
        stillOpen.openNow = [.history]
        #expect(selector.decide(stillOpen) == .preload(.settings), "preloaded a page that is open")

        var stale = recent
        stale.now = 50 + PreloadSelector.Timing().recentOpen + 1
        stale.lastOpened[.history] = 1
        #expect(selector.decide(stale) == .preload(.newTab))
    }

    /// Equal open times fall to the greater raw value, whatever order the dictionary iterates in.
    @Test func equalOpenTimesPickAFixedPage() {
        let tied = Facts(now: 100, firstPaintAt: 1, lastOpened: [.cloud: 50, .history: 50, .settings: 50])
        #expect(selector.decide(tied) == .preload(.settings))

        var settingsOpen = tied
        settingsOpen.openNow = [.settings]
        #expect(selector.decide(settingsOpen) == .preload(.history))

        let pair = Facts(now: 100, firstPaintAt: 1, lastOpened: [.history: 50, .cloud: 50])
        #expect(selector.decide(pair) == .preload(.history))
    }

    // MARK: Properties

    static let corpusSize = 2_000

    @Test func atMostOnePreloadAndNeverOverAHeldPage() {
        for index in 0..<Self.corpusSize {
            let facts = Self.corpus(index)
            let decision = selector.decide(facts)
            if facts.held != nil {
                #expect(decision == .keep || decision == .drop, "case \(index): \(decision) over a held page")
            }
            if case .preload(let page) = decision {
                #expect(facts.held == nil, "case \(index)")
                #expect(!(page.isSingleton && facts.openNow.contains(page)), "case \(index): \(page) is open")
            }
        }
    }

    @Test func nothingStartsUnderPressure() {
        for index in 0..<Self.corpusSize {
            let facts = Self.corpus(index)
            let decision = selector.decide(facts)
            if facts.pressure != .normal {
                #expect(decision == (facts.held == nil ? .blocked : .drop), "case \(index): \(decision) at \(facts.pressure)")
            } else {
                #expect(decision != .drop && decision != .blocked, "case \(index): \(decision) at normal pressure")
            }
        }
    }

    @Test func aPreloadWaitsForPaintOrDeadlineThenQuietInput() {
        let timing = PreloadSelector.Timing()
        for index in 0..<Self.corpusSize {
            let facts = Self.corpus(index)
            guard case .preload = selector.decide(facts) else { continue }
            let painted = facts.firstPaintAt.map { $0 <= facts.now } ?? false
            #expect(painted || facts.now >= facts.startedAt + timing.firstPaintDeadline, "case \(index): before paint and deadline")
            let gate = min(facts.firstPaintAt ?? .infinity, facts.startedAt + timing.firstPaintDeadline)
            #expect(facts.now >= gate + timing.quietInput, "case \(index): within 750 ms of the paint gate")
            if let input = facts.lastInputAt {
                #expect(facts.now >= input + timing.quietInput, "case \(index): within 750 ms of input")
            }
        }
    }

    /// A wait lies in the future and ends in a preload at its moment.
    @Test func aWaitNamesTheMomentTheDecisionChanges() {
        for index in 0..<Self.corpusSize {
            let facts = Self.corpus(index)
            guard case .later(let until, _) = selector.decide(facts) else { continue }
            #expect(until > facts.now, "case \(index): a wait in the past")
            var later = facts
            later.now = until
            guard case .preload = selector.decide(later) else {
                Issue.record("case \(index): no preload at the wait's end")
                continue
            }
        }
    }

    /// A wait that names the paint is ended sooner by it; one that does not is not changed by it.
    @Test func aWaitNamesThePaintOnlyWhenThePaintCanOpenTheGateSooner() {
        for index in 0..<Self.corpusSize {
            let facts = Self.corpus(index)
            guard case .later(let until, let orFirstPaint) = selector.decide(facts) else { continue }
            var painted = facts
            painted.firstPaintAt = facts.now
            if orFirstPaint {
                #expect(facts.firstPaintAt == nil, "case \(index): woke on a paint that has come")
                #expect(selector.earliestStart(painted) <= until, "case \(index): the paint moved the start later")
                if facts.lastInputAt == nil {
                    #expect(selector.earliestStart(painted) < until, "case \(index): the paint changed nothing")
                }
            } else if facts.firstPaintAt == nil {
                #expect(selector.decide(painted) == .later(at: until, orFirstPaint: false),
                        "case \(index): a paint the wait ignores changed the decision")
            }
        }
    }

    /// The decision is the same whatever order `lastOpened` was built in, on the corpus and on a
    /// variant where every open has the same time.
    @Test func thePageDoesNotDependOnTheDictionaryOrder() {
        for index in 0..<Self.corpusSize {
            let facts = Self.corpus(index)
            var tied = facts
            if let time = facts.lastOpened.values.max() {
                tied.lastOpened = tied.lastOpened.mapValues { _ in time }
            }
            for base in [facts, tied] {
                let expected = selector.decide(base)
                for order in Self.permutations(Array(base.lastOpened)) {
                    var rebuilt = base
                    rebuilt.lastOpened = [:]
                    for (page, time) in order { rebuilt.lastOpened[page] = time }
                    #expect(selector.decide(rebuilt) == expected, "case \(index): the page followed the insertion order")
                }
            }
        }
    }

    static func permutations<Element>(_ items: [Element]) -> [[Element]] {
        guard let first = items.first else { return [[]] }
        return permutations(Array(items.dropFirst())).flatMap { rest in
            (0...rest.count).map { position in
                var order = rest
                order.insert(first, at: position)
                return order
            }
        }
    }

    /// Facts set `index`: a fixed pseudo-random draw, the same on every run and every machine.
    static func corpus(_ index: Int) -> Facts {
        var random = SplitMix64(seed: UInt64(index) &* 0x2545_F491 &+ 42)
        let now = Double(random.next() % 20_000) / 1_000
        var facts = Facts(now: now, startedAt: Double(random.next() % 1_000) / 1_000)
        if !random.oneIn(3) { facts.firstPaintAt = facts.startedAt + Double(random.next() % 6_000) / 1_000 }
        if !random.oneIn(3) { facts.lastInputAt = Double(random.next() % 20_000) / 1_000 }
        facts.pressure = random.pick([MemoryPressureLevel.normal, .normal, .normal, .warning, .critical])
        for page in Page.allCases where random.oneIn(3) {
            facts.lastOpened[page] = Double(random.next() % 1_200_000) / 1_000 - 600
            if random.oneIn(2) { facts.openNow.insert(page) }
        }
        if random.oneIn(4) { facts.held = random.pick(Page.allCases) }
        return facts
    }
}
