import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextSettings
import Testing

/// ``UrgentDiscardRanker`` (p13-webui.md section 3.C, task 092): the one urgent pass over browser tabs,
/// agent chats and cmux pages, in Chrome's page_discarding_helper.cc order (protected pages last, then
/// the longest hidden first), which stops at the reclaim target or after one page with no target; and
/// the two owners' candidates (``HibernationPlanner/urgentCandidates(_:candidates:)``,
/// ``PageLifecyclePlanner/urgentCandidates(_:conditions:)``) that feed it.
@Suite struct UrgentDiscardRankingTests {
    typealias Candidate = UrgentDiscardRanker.Candidate

    let ranker = UrgentDiscardRanker()

    func tab(_ key: String, hiddenFor: Double, bytes: UInt64? = nil, isProtected: Bool = false) -> Candidate {
        Candidate(key: key, kind: .browser, hiddenFor: hiddenFor, estimatedBytes: bytes, isProtected: isProtected)
    }

    func page(_ key: String, hiddenFor: Double, kind: ContentKind = .internalPage, bytes: UInt64? = nil) -> Candidate {
        Candidate(key: key, kind: kind, hiddenFor: hiddenFor, estimatedBytes: bytes)
    }

    // MARK: Order

    @Test func tabsChatsAndPagesRankTogetherLongestHiddenFirstRecentlyVisibleLast() {
        let candidates = [
            tab("tab-700", hiddenFor: 700),
            page("settings-300", hiddenFor: 300),
            page("chat-900", hiddenFor: 900, kind: .agentPage),
            tab("tab-20", hiddenFor: 20),
            page("history-1800", hiddenFor: 1_800),
        ]
        #expect(ranker.ranked(candidates).map(\.key) == ["history-1800", "chat-900", "tab-700", "settings-300", "tab-20"],
                "pages hidden under 10 minutes are protected and go after every other one")
    }

    @Test func aPageItsOwnerProtectsGoesAfterEveryUnprotectedOne() {
        let candidates = [tab("kept", hiddenFor: 3_600, isProtected: true), page("old", hiddenFor: 700), tab("recent", hiddenFor: 30)]
        #expect(ranker.ranked(candidates).map(\.key) == ["old", "kept", "recent"],
                "among protected pages the longest hidden still goes first")
    }

    @Test func equalHiddenTimesBreakTiesByKeyAndAKeyListedTwiceCountsOnce() {
        let candidates = [page("b", hiddenFor: 900), tab("a", hiddenFor: 900), page("a", hiddenFor: 1_000)]
        let ranked = ranker.ranked(candidates)
        #expect(ranked.map(\.key) == ["a", "b"])
        #expect(ranked.first?.kind == .browser, "the first entry of a repeated key is the one kept")
    }

    // MARK: The pass

    @Test func withNoTargetOnePassDiscardsOnePage() {
        let pass = ranker.pass([tab("a", hiddenFor: 900), page("b", hiddenFor: 1_200), page("c", hiddenFor: 20)], reclaimTarget: nil)
        #expect(pass.keys == ["b"], "Chrome's urgent policy discards one page per critical event")
        #expect(!pass.reachedTarget)
        #expect(ranker.pass([], reclaimTarget: nil).discards.isEmpty)
    }

    @Test func aTargetStopsThePassAtTheFirstPageThatReachesIt() {
        let mb: UInt64 = 1 << 20
        let candidates = [
            tab("a", hiddenFor: 3_000, bytes: 100 * mb), page("b", hiddenFor: 2_000),
            tab("c", hiddenFor: 1_000, bytes: 150 * mb), tab("d", hiddenFor: 900, bytes: 500 * mb),
        ]
        let pass = ranker.pass(candidates, reclaimTarget: 200 * mb)
        #expect(pass.keys == ["a", "b", "c"], "an unmeasured page counts as nothing and the pass goes on")
        #expect(pass.estimatedBytes == 250 * mb)
        #expect(pass.reachedTarget)

        let short = ranker.pass(candidates, reclaimTarget: 10_000 * mb)
        #expect(short.keys == ["a", "b", "c", "d"], "a target out of reach takes every candidate")
        #expect(!short.reachedTarget)

        #expect(ranker.pass(candidates, reclaimTarget: 0).discards.isEmpty, "a target already met discards nothing")
    }

    @Test func estimatesThatOverflowSaturate() {
        let pass = ranker.pass([tab("a", hiddenFor: 900, bytes: .max), tab("b", hiddenFor: 800, bytes: .max)], reclaimTarget: .max)
        #expect(pass.keys == ["a"])
        #expect(pass.estimatedBytes == .max)
    }

    // MARK: Properties

    /// Over a fixed pseudo-random corpus: the ranking is a permutation of the distinct keys whatever the
    /// input order, protected pages never precede unprotected ones, hidden time never grows down a
    /// class, a pass is a prefix of the ranking, with no target it holds one page, and with a target it
    /// stops at the first page that reaches it.
    @Test(arguments: 0..<300) func rankingAndPassProperties(_ index: Int) {
        let (candidates, target) = Self.corpus(index)
        let ranked = ranker.ranked(candidates)
        #expect(Set(ranked.map(\.key)) == Set(candidates.map(\.key)))
        #expect(ranked.count == Set(candidates.map(\.key)).count)
        #expect(ranked.map(\.key) == ranker.ranked(candidates.reversed()).map(\.key)
                || Set(candidates.map(\.key)).count != candidates.count, "the order depends on the input order")
        for (earlier, later) in zip(ranked, ranked.dropFirst()) {
            let (left, right) = (ranker.isProtected(earlier), ranker.isProtected(later))
            #expect(!left || right, "a protected page went before an unprotected one")
            if left == right { #expect(earlier.hiddenFor >= later.hiddenFor) }
        }

        let one = ranker.pass(candidates, reclaimTarget: nil)
        #expect(one.discards.count == min(1, ranked.count))
        #expect(one.discards == Array(ranked.prefix(one.discards.count)))

        let pass = ranker.pass(candidates, reclaimTarget: target)
        #expect(pass.discards == Array(ranked.prefix(pass.discards.count)))
        let sum = pass.discards.reduce(UInt64(0)) { $0 + ($1.estimatedBytes ?? 0) }
        #expect(pass.estimatedBytes == sum)
        #expect(pass.reachedTarget == (sum >= target))
        let beforeLast = pass.discards.dropLast().reduce(UInt64(0)) { $0 + ($1.estimatedBytes ?? 0) }
        #expect(pass.discards.isEmpty || beforeLast < target, "the pass went on past its target")
        #expect(pass.reachedTarget || pass.discards.count == ranked.count, "the pass stopped short of its target")
    }

    /// Case `index`: candidates of every kind, hidden times around the protection window, some
    /// unmeasured, a few repeated keys, and a target from nothing to more than all of them.
    static func corpus(_ index: Int) -> ([Candidate], UInt64) {
        var random = SplitMix64(seed: UInt64(index) &* 0x5851_F42D &+ 92)
        let hidden: [Double] = [10, 30, 300, 599.5, 600, 600.5, 900, 3_600]
        let kinds: [ContentKind] = [.browser, .agentPage, .internalPage]
        let count = Int(random.next() % 12)
        let candidates = (0..<count).map { _ in
            Candidate(key: "k\(random.next() % 16)", kind: random.pick(kinds), hiddenFor: random.pick(hidden),
                      estimatedBytes: random.oneIn(4) ? nil : (random.next() % 400) << 20, isProtected: random.oneIn(5))
        }
        return (candidates, random.oneIn(6) ? 0 : (random.next() % 2_000) << 20)
    }

    // MARK: The owners' candidates

    @Test func browserTabsJoinOnlyWhenTheUrgentEligibilityLetsThemGo() {
        var old = HibernationPlanner.Candidate(key: "old", hiddenFor: 900, memoryBytes: UInt64(80) << 20)
        old.recentlyKept = true
        let candidates = [
            old,
            HibernationPlanner.Candidate(key: "devtools", hiddenFor: 900, hasDevTools: true),
            HibernationPlanner.Candidate(key: "pinned", hiddenFor: 900, isPinned: true),
            HibernationPlanner.Candidate(key: "fresh", hiddenFor: 5),
            HibernationPlanner.Candidate(key: "plain", hiddenFor: 30),
        ]
        // `browser.hibernation` written: with nothing written no tab goes on its own (trunk #25920).
        let urgent = HibernationPlanner.urgentCandidates(PageLifecyclePlannerTests.discarding, candidates: candidates)
        #expect(urgent.map(\.key) == ["old", "plain"], "a kept or just-hidden tab joined the urgent pass")
        #expect(urgent.first?.isProtected == true, "a tab the probe kept lately must go after the others")
        #expect(urgent.first?.estimatedBytes == UInt64(80) << 20)
        #expect(urgent.allSatisfy { $0.kind == .browser })

        var off = PageLifecyclePlannerTests.discarding
        off.mode = .off
        #expect(HibernationPlanner.urgentCandidates(off, candidates: candidates).isEmpty, "hibernation off let a tab go")
        #expect(HibernationPlanner.urgentCandidates(.fallback, candidates: candidates).isEmpty,
                "no browser.hibernation written let a tab go")
    }

    @Test func pagesJoinWhenNothingBlocksTheirDiscardWhateverTheirTimeout() {
        typealias Page = PageLifecyclePlanner.Page
        let planner = PageLifecyclePlanner()
        let pages = [
            Page(key: "chat", group: "agent", hiddenFor: 40),
            Page(key: "settings", group: "privileged", hiddenFor: 120),
            Page(key: "busy", group: "agent", hiddenFor: 900, keepReasons: [.turnRunning]),
            Page(key: "draft", group: "agent", hiddenFor: 900, keepReasons: [.draft]),
            Page(key: "gone", group: "viewer", hiddenFor: 900, isDiscarded: true),
            Page(key: "shown", group: "viewer", isShown: true),
            Page(key: "recent", group: "viewer", hiddenFor: 5),
        ]
        let urgent = planner.urgentCandidates(pages, conditions: PageLifecyclePlannerTests.written(.critical))
        #expect(Set(urgent.map(\.key)) == ["chat", "settings"])
        #expect(urgent.first { $0.key == "chat" }?.kind == .agentPage)
        #expect(urgent.first { $0.key == "settings" }?.kind == .internalPage)

        let mostRecent = [Page(key: "only", group: "viewer", hiddenFor: 30)]
        #expect(planner.urgentCandidates(mostRecent, conditions: PageLifecyclePlannerTests.written()).map(\.key) == ["only"],
                "the most recently used role blocks a freeze only")

        var off = PageLifecyclePlannerTests.discarding
        off.mode = .off
        #expect(planner.urgentCandidates(pages, conditions: .init(setting: off, pressure: .critical)).isEmpty)
        // No `browser.hibernation` written: no page goes on its own, at critical pressure too, as no browser tab does.
        #expect(planner.urgentCandidates(pages, conditions: .init(pressure: .critical)).isEmpty)
    }

    /// The urgent candidates of a page are exactly the live hidden pages the planner would discard once
    /// their timeout passed: no discard-blocking reason, hidden at least the minimum.
    @Test(arguments: 0..<200) func aPageCandidateNeverHoldsADiscardBlockingReason(_ index: Int) {
        let (pages, conditions) = PageLifecyclePlannerTests.corpus(index)
        let planner = PageLifecyclePlanner()
        let keys = Set(planner.urgentCandidates(pages, conditions: conditions).map(\.key))
        let mostRecent = pages.filter { !$0.isShown }.min { ($0.hiddenFor, $0.key) < ($1.hiddenFor, $1.key) }?.key
        for page in pages {
            let reasons = planner.keepReasons(of: page, conditions: conditions, isMostRecentlyUsed: page.key == mostRecent)
            let eligible = !page.isShown && !page.isDiscarded && page.hiddenFor >= planner.timing.minimumHidden
                && !reasons.contains(where: \.blocksDiscard)
            #expect(keys.contains(page.key) == eligible, "page \(page.key) with \(reasons)")
        }
    }
}
