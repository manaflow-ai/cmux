import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextSettings
import Testing

/// ``PageLifecyclePlanner`` (p13-webui.md section 3.C, task 021): the exemptions AgentPageHibernation
/// had for chat pages, ported to the planner every cmux page shares, and its properties over a fixed
/// pseudo-random corpus: a shown page is active, a freeze-blocking reason never reaches Frozen, a
/// discard-blocking reason never reaches Discarded, the most recently hidden page never freezes, and
/// the next check is the earliest time any page changes.
@Suite struct PageLifecyclePlannerTests {
    typealias Page = PageLifecyclePlanner.Page
    typealias Reason = PageLifecyclePlanner.KeepReason

    let planner = PageLifecyclePlanner()

    func page(_ key: String, hiddenFor: Double, _ reasons: Set<Reason> = []) -> Page {
        Page(key: key, group: "agent", hiddenFor: hiddenFor, keepReasons: reasons)
    }

    /// A page hidden a moment ago: the most recently hidden one, so the page under test is not.
    var fresh: Page { page("fresh", hiddenFor: 0) }

    // MARK: AgentPageHibernation's exemptions

    @Test func aChatHiddenPastTheTimeoutIsDiscardedAndABusyOneKeepsItsPage() {
        let plan = planner.plan([page("quiet", hiddenFor: 301), page("busy", hiddenFor: 400, [.turnRunning]), fresh],
                                conditions: .init())
        #expect(plan.discards == ["quiet"])
        #expect(plan.state(of: "quiet") == .discarded)
        #expect(plan.state(of: "busy") == .hidden, "a chat whose agent works froze or went")
        #expect(plan.decisions["busy"]?.keptBy == [.turnRunning])
        #expect(plan.decisions["busy"]?.nextDeadline == nil, "only the turn's end lets a busy chat go")
    }

    @Test func memoryPressureDiscardsSoonerButOffKeepsEveryPage() {
        var off = BrowserHibernationSetting.fallback
        off.mode = .off
        let kept = planner.plan([page("off", hiddenFor: 3_600), fresh], conditions: .init(setting: off, pressure: .critical))
        #expect(kept.state(of: "off") == .frozen, "hibernation off discarded a page")
        #expect(kept.decisions["off"]?.keptBy == [.hibernationOff])
        #expect(kept.discards.isEmpty)

        let early = planner.plan([page("pressed", hiddenFor: 9), page("fresher", hiddenFor: 1)], conditions: .init(pressure: .critical))
        #expect(early.state(of: "pressed") == .hidden, "discarded before the composer's last keystrokes reached acpmux")
        #expect(early.decisions["pressed"]?.nextDeadline == 1)
        let critical = planner.plan([page("pressed", hiddenFor: 10), page("fresher", hiddenFor: 2)], conditions: .init(pressure: .critical))
        #expect(critical.discards == ["pressed"], "critical pressure kept a hidden chat's page")

        let warning = planner.plan([page("a", hiddenFor: 60), page("b", hiddenFor: 59), fresh], conditions: .init(pressure: .warning))
        #expect(warning.discards == ["a"])
        #expect(warning.state(of: "b") == .frozen)
        #expect(warning.decisions["b"]?.nextDeadline == 1)
    }

    @Test func aLoneHiddenChatGoesOnItsOwnDeadline() {
        let hidden = planner.plan([page("alone", hiddenFor: 0)], conditions: .init())
        #expect(hidden.state(of: "alone") == .hidden)
        #expect(hidden.decisions["alone"]?.keptBy == [.recentlyVisible, .mostRecentlyUsed])
        #expect(hidden.nextCheck == 300, "the hide armed no deadline")
        let due = planner.plan([page("alone", hiddenFor: 300)], conditions: .init())
        #expect(due.discards == ["alone"], "a lone hidden chat kept its page")
    }

    @Test func withTheTurnWatchDownEveryChatKeepsItsPage() {
        let unknown = planner.plan([page("unknown", hiddenFor: 3_600, [.turnsUnknown]), fresh], conditions: .init(pressure: .critical))
        #expect(unknown.state(of: "unknown") == .hidden, "a chat whose turn nobody knows froze or went")
        #expect(unknown.decisions["unknown"]?.keptBy == [.turnsUnknown])
        let back = planner.plan([page("unknown", hiddenFor: 3_600), fresh], conditions: .init())
        #expect(back.discards == ["unknown"], "the watch came back and the idle chat kept its page")
    }

    @Test func pinnedNewTabShellRemoteAndWaitingChatsFreezeButStay() {
        let reasons: [Reason] = [.pinned, .preload, .shellCommandRan, .remoteChat, .awaitingPerson, .unrestorable, .draft,
                                 .userEdits, .formInteraction, .beforeUnload]
        for reason in reasons {
            let plan = planner.plan([page("kept", hiddenFor: 3_600, [reason]), fresh], conditions: .init(pressure: .critical))
            #expect(plan.state(of: "kept") == .frozen, "\(reason) did not let the page freeze or let it go")
            #expect(plan.decisions["kept"]?.keptBy == [reason])
            #expect(plan.decisions["kept"]?.nextDeadline == nil)
        }
        var pinnedToo = BrowserHibernationSetting.fallback
        pinnedToo.includesPinnedTabs = true
        let plan = planner.plan([page("pinned", hiddenFor: 3_600, [.pinned]), fresh], conditions: .init(setting: pinnedToo))
        #expect(plan.discards == ["pinned"], "a pinned page stayed though pinned tabs hibernate")
    }

    // MARK: Freeze, pace and Low Power Mode

    @Test func aHiddenPageFreezesOnceNoLongerRecentlyVisible() {
        let before = planner.plan([page("p", hiddenFor: 9.5), fresh], conditions: .init())
        #expect(before.state(of: "p") == .hidden)
        #expect(before.decisions["p"]?.nextDeadline == 0.5)
        let after = planner.plan([page("p", hiddenFor: 10), fresh], conditions: .init())
        #expect(after.state(of: "p") == .frozen)
        #expect(after.decisions["p"]?.nextDeadline == 290)
        let lowPower = planner.plan([page("p", hiddenFor: 3), fresh], conditions: .init(lowPowerMode: true))
        #expect(lowPower.state(of: "p") == .frozen, "Low Power Mode kept a page warm as long as without it")
    }

    @Test func discardsGoLongestHiddenFirstAtThePace() {
        let pages = [page("a", hiddenFor: 400), page("b", hiddenFor: 900), page("c", hiddenFor: 600), page("d", hiddenFor: 301), fresh]
        let normal = planner.plan(pages, conditions: .init())
        #expect(normal.discards == ["b", "c"])
        #expect(normal.state(of: "a") == .frozen)
        #expect(normal.decisions["a"]?.nextDeadline == 5)
        #expect(normal.nextCheck == 5)
        let urgent = planner.plan(pages, conditions: .init(pressure: .critical))
        #expect(urgent.discards == ["b"], "pressure took more than Chrome's one page per pass")
    }

    @Test func onlyThePlannerSetsTheDerivedReasons() {
        let plan = planner.plan([page("p", hiddenFor: 600, [.visible, .recentlyVisible, .mostRecentlyUsed, .hibernationOff]), fresh],
                                conditions: .init())
        #expect(plan.discards == ["p"], "a page kept itself with a reason only the planner knows")
    }

    @Test func aDiscardedPageStaysSoUntilShown() {
        let plan = planner.plan([Page(key: "gone", hiddenFor: 5, isDiscarded: true),
                                 Page(key: "back", isShown: true, keepReasons: [.loading], isDiscarded: true)],
                                conditions: .init())
        #expect(plan.state(of: "gone") == .discarded)
        #expect(plan.state(of: "back") == .active)
        #expect(plan.discards.isEmpty)
        #expect(plan.nextCheck == nil)
    }

    // MARK: Properties

    static let corpusSize = 600

    @Test func aShownPageIsActive() {
        for index in 0..<Self.corpusSize {
            let (pages, conditions) = Self.corpus(index)
            let plan = planner.plan(pages, conditions: conditions)
            for page in pages where page.isShown {
                #expect(plan.state(of: page.key) == .active, "case \(index): shown \(page.key)")
            }
            #expect(Set(plan.decisions.keys) == Set(pages.map(\.key)), "case \(index): a page has no decision")
        }
    }

    @Test func aFreezeBlockingReasonNeverReachesFrozen() {
        for index in 0..<Self.corpusSize {
            let (pages, conditions) = Self.corpus(index)
            let plan = planner.plan(pages, conditions: conditions)
            for page in pages where !page.isShown && !page.isDiscarded {
                let reasons = page.keepReasons.subtracting(Reason.derived)
                guard reasons.contains(where: \.blocksFreeze) else { continue }
                #expect(plan.state(of: page.key) == .hidden, "case \(index): \(page.key) \(reasons)")
            }
        }
    }

    @Test func aDiscardBlockingReasonNeverReachesDiscarded() {
        let minimumHidden = PageLifecyclePlanner.Timing().minimumHidden
        for index in 0..<Self.corpusSize {
            let (pages, conditions) = Self.corpus(index)
            let plan = planner.plan(pages, conditions: conditions)
            for page in pages where !page.isShown && !page.isDiscarded {
                var reasons = page.keepReasons.subtracting(Reason.derived)
                if conditions.setting.includesPinnedTabs { reasons.remove(.pinned) }
                let kept = reasons.contains(where: \.blocksDiscard) || !conditions.setting.isEnabled || page.hiddenFor < minimumHidden
                if kept {
                    #expect(plan.state(of: page.key) != .discarded, "case \(index): \(page.key) \(reasons)")
                    #expect(!plan.discards.contains(page.key))
                }
            }
        }
    }

    @Test func theMostRecentlyHiddenPageNeverFreezes() {
        for index in 0..<Self.corpusSize {
            let (pages, conditions) = Self.corpus(index)
            let live = pages.filter { !$0.isShown && !$0.isDiscarded }
            guard let recent = live.min(by: { ($0.hiddenFor, $0.key) < ($1.hiddenFor, $1.key) }) else { continue }
            let plan = planner.plan(pages, conditions: conditions)
            #expect(plan.state(of: recent.key) != .frozen, "case \(index): \(recent.key)")
            if plan.state(of: recent.key) == .hidden {
                #expect(plan.decisions[recent.key]?.keptBy.contains(.mostRecentlyUsed) == true)
            }
        }
    }

    /// The next check is the earliest per-page deadline, nothing changes before it, and something
    /// changes at it. Checked on a settled set (the plan's discards done), as the controller replans.
    @Test func theNextCheckIsTheEarliestChange() {
        var checked = 0
        for index in 0..<Self.corpusSize {
            let (pages, conditions) = Self.corpus(index)
            let settled = settle(pages, conditions)
            let plan = planner.plan(settled, conditions: conditions)
            #expect(plan.discards.isEmpty)
            #expect(plan.nextCheck == plan.decisions.values.compactMap(\.nextDeadline).min(), "case \(index)")
            guard let next = plan.nextCheck else { continue }
            #expect(next > 0, "case \(index): a deadline in the past")
            let before = planner.plan(Self.advance(settled, by: next / 2), conditions: conditions)
            #expect(Self.states(before) == Self.states(plan), "case \(index): a page changed before the next check")
            let at = planner.plan(Self.advance(settled, by: next), conditions: conditions)
            #expect(Self.states(at) != Self.states(plan), "case \(index): nothing changed at the next check \(next)")
            checked += 1
        }
        #expect(checked > Self.corpusSize / 8, "the corpus has too few deadlines to test")
    }

    // MARK: Corpus

    /// Performs every discard the planner asks for until it asks for none.
    func settle(_ pages: [Page], _ conditions: PageLifecyclePlanner.Conditions) -> [Page] {
        var pages = pages
        while true {
            let discards = Set(planner.plan(pages, conditions: conditions).discards)
            if discards.isEmpty { return pages }
            for index in pages.indices where discards.contains(pages[index].key) { pages[index].isDiscarded = true }
        }
    }

    static func advance(_ pages: [Page], by seconds: Double) -> [Page] {
        pages.map { page in
            var page = page
            if !page.isShown { page.hiddenFor += seconds }
            return page
        }
    }

    static func states(_ plan: PageLifecyclePlanner.Plan) -> [String: PageLifecyclePlanner.State] {
        plan.decisions.mapValues(\.state)
    }

    /// Case `index`: a fixed pseudo-random draw, the same on every run and every machine. Hidden
    /// times are halves of a second (exact in a Double), clustered at the planner's thresholds.
    static func corpus(_ index: Int) -> ([Page], PageLifecyclePlanner.Conditions) {
        var random = SplitMix64(seed: UInt64(index) &* 0x2545_F491 &+ 21)
        let hidden: [Double] = [0, 0.5, 2.5, 3, 9.5, 10, 10.5, 30, 59.5, 60, 61, 299.5, 300, 301, 3_600]
        let pressures: [MemoryPressureLevel] = [.normal, .normal, .warning, .critical]
        var setting = BrowserHibernationSetting.fallback
        if random.oneIn(6) { setting.mode = .off }
        setting.includesPinnedTabs = random.oneIn(3)
        let conditions = PageLifecyclePlanner.Conditions(setting: setting, pressure: random.pick(pressures), lowPowerMode: random.oneIn(4))
        let count = 1 + Int(random.next() % 10)
        let pages = (0..<count).map { number in
            let offset = Double(random.next() % 200) / 2
            let reasons = Set(Reason.allCases.filter { _ in random.oneIn(14) })
            return Page(key: "p\(number)", group: random.pick(["agent", "viewer", "privileged"]), isShown: random.oneIn(4),
                        hiddenFor: random.oneIn(2) ? random.pick(hidden) : offset * 4, keepReasons: reasons,
                        isDiscarded: random.oneIn(10))
        }
        return (pages, conditions)
    }
}
