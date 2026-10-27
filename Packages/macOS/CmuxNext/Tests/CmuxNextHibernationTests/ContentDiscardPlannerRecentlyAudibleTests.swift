import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextSettings
import Testing

/// Chrome's recently audible protection (`DiscardEligibilityPolicy::CanDiscard`,
/// chrome/browser/performance_manager/policies/discard_eligibility_policy.cc: `kRecentlyAudible`
/// for `kTabAudioProtectionTime`, one minute): content whose sound ended less than a minute ago is
/// protected from the timeout and from memory pressure, and the end of that minute is the planner's
/// next look (its one deadline), not a timer of its own.
@Suite struct ContentDiscardPlannerRecentlyAudibleTests {
    let planner = ContentDiscardPlanner()
    let setting = BrowserHibernationSetting.fallback

    func page(_ key: String = "song", minutes: Double = 45, heardSecondsAgo: Double?) -> ContentDiscardPlanner.Candidate {
        var candidate = ContentDiscardPlanner.Candidate(key: key, hiddenFor: minutes * 60)
        candidate.secondsSinceAudible = heardSecondsAgo
        return candidate
    }

    @Test func theProtectionIsChromesOneMinute() {
        #expect(DiscardRule.audioProtectionTime == 60)
        #expect(DiscardRule.registered.contains { $0.reason == .recentlyAudible })
        #expect(CannotDiscardReason(chromeReason: "kRecentlyAudible") == .recentlyAudible)
    }

    @Test(arguments: [MemoryPressureLevel.normal, .warning, .critical])
    func soundThirtySecondsAgoIsProtectedUntilItsMinuteEnds(pressure: MemoryPressureLevel) {
        let plan = HibernationPlanner.plan(setting, pressure: pressure, candidates: [page(heardSecondsAgo: 30)])
        #expect(plan.due.isEmpty)
        #expect(plan.exemptions["song"] == .recentlyAudible)
        #expect(plan.nextCheck.map { abs($0 - 30) < 1e-9 } == true, "the minute's end is the next look: \(String(describing: plan.nextCheck))")
    }

    @Test(arguments: [MemoryPressureLevel.normal, .warning, .critical])
    func soundSixtyOneSecondsAgoIsEligible(pressure: MemoryPressureLevel) {
        let plan = HibernationPlanner.plan(setting, pressure: pressure, candidates: [page(heardSecondsAgo: 61)])
        #expect(plan.due == ["song"])
        #expect(plan.exemptions["song"] == nil)
    }

    @Test func itProtectsFromTheTimeoutAndPressureButNotFromThePersonsOwnDiscard() {
        let recent = page(heardSecondsAgo: 30)
        for reason in [DiscardReason.proactive, .urgent] {
            let eligibility = planner.eligibility(of: recent, setting: setting, for: reason)
            #expect(eligibility.result == .protected)
            #expect(eligibility.reasons == [.recentlyAudible])
            #expect(eligibility.endsIn.map { abs($0 - 30) < 1e-9 } == true)
        }
        #expect(planner.eligibility(of: recent, setting: setting, for: .external).result == .eligible)
        #expect(planner.eligibility(of: page(heardSecondsAgo: nil), setting: setting, for: .proactive).result == .eligible)
        #expect(planner.eligibility(of: page(heardSecondsAgo: 60), setting: setting, for: .proactive).result == .eligible)
    }

    /// Content that plays now is kept by the audio rule, which only an event (the sound's end) ends:
    /// no deadline, the end of the sound replans.
    @Test func contentThatPlaysNowHasNoDeadline() {
        var playing = page(heardSecondsAgo: 0)
        playing.isAudible = true
        let eligibility = planner.eligibility(of: playing, setting: setting, for: .urgent)
        #expect(eligibility.reasons == [.audio, .recentlyAudible])
        #expect(eligibility.endsIn == nil)
        let plan = HibernationPlanner.plan(setting, pressure: .critical, candidates: [playing])
        #expect(plan.exemptions["song"] == .audio)
        #expect(plan.nextCheck == nil)
    }

    /// Without pressure, content whose timeout is still ten minutes off needs no look when its
    /// minute ends: the next look stays its timeout.
    @Test func aLaterTimeoutStaysTheNextLook() {
        let plan = HibernationPlanner.plan(setting, pressure: .normal, candidates: [page(minutes: 20, heardSecondsAgo: 30)])
        #expect(plan.exemptions["song"] == .recentlyAudible)
        #expect(plan.nextCheck.map { abs($0 - 600) < 1e-9 } == true, "\(String(describing: plan.nextCheck))")
    }

    /// The protected content does not hold up the rest: under pressure the next page goes, and the
    /// planner still looks again when the protection ends.
    @Test func othersStillGoUnderPressure() {
        let plan = HibernationPlanner.plan(setting, pressure: .warning, candidates: [
            page("song", minutes: 50, heardSecondsAgo: 10), page("docs", minutes: 5, heardSecondsAgo: nil),
        ])
        #expect(plan.due == ["docs"])
        #expect(plan.exemptions["song"] == .recentlyAudible)
        #expect(plan.nextCheck.map { $0 <= 50 } == true)
    }

    /// Every kind plans through the rule (a conversation or a terminal that played sound too).
    @Test func everyKindIsProtected() {
        for kind in ContentKind.allCases {
            var recent = page(heardSecondsAgo: 5)
            recent.kind = kind
            let plan = planner.plan(setting, for: .urgent, threshold: 0, pace: .chromeUrgent, candidates: [recent])
            #expect(plan.due.isEmpty, "\(kind)")
            #expect(plan.exemptions["song"] == .recentlyAudible, "\(kind)")
            #expect(plan.nextCheck.map { abs($0 - 55) < 1e-9 } == true, "\(kind): \(String(describing: plan.nextCheck))")
        }
    }

    /// The minute ran out and the page is not due: the plan gives no reason, so the one held from
    /// the last plan goes. A due page keeps it until its probe answers; a probe's `.audio` stays.
    @Test func anEndedSoundReasonIsDroppedOnceThePlanGivesNone() throws {
        let plan = HibernationPlanner.plan(setting, pressure: .normal,
                                           candidates: [page("ended", minutes: 1, heardSecondsAgo: 61), page("due", heardSecondsAgo: 61),
                                                        page("probed", minutes: 1, heardSecondsAgo: nil), page("kept", heardSecondsAgo: 10)])
        try #require(plan.due == ["due"])
        let held: [String: CannotDiscardReason] = ["ended": .recentlyAudible, "due": .recentlyAudible, "probed": .audio, "kept": .recentlyAudible]
        #expect(plan.endedSoundReasons(of: ["ended", "due", "probed", "kept"], held: held, probeKept: { $0 == "probed" }) == ["ended"])
        #expect(plan.endedSoundReasons(of: ["probed"], held: held, probeKept: { _ in false }) == ["probed"],
                "a plan-only `.audio` whose tab stopped playing stayed")
        #expect(plan.endedSoundReasons(of: ["ended"], held: ["ended": .formInput], probeKept: { _ in false }).isEmpty,
                "a probe's reason other than sound was dropped")
    }
}
