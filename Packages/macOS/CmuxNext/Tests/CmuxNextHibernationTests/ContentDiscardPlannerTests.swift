import CmuxNextHibernation
import CmuxNextSettings
import Testing

/// ``ContentDiscardPlanner`` decides like Chrome's `DiscardEligibilityPolicy::CanDiscard`
/// (chrome/browser/performance_manager/policies/discard_eligibility_policy.cc): the worst result of
/// the matching rules wins, protected content never goes for the timeout or for pressure, only a
/// disallowed rule keeps it from the person's own discard, and every one of Chrome's 30
/// `CannotDiscardReason`s has a case.
@Suite struct ContentDiscardPlannerTests {
    let planner = ContentDiscardPlanner()
    let setting = BrowserHibernationSetting.fallback

    /// A timeout pace for the tests: two per pass, every 5 s, no minimum.
    let timeoutPace = ContentDiscardPlanner.Pace(perPass: 2, interval: 5, minimumHidden: 0)

    func page(_ key: String = "p", kind: ContentKind = .browser, hiddenFor: Double = 7_200) -> ContentDiscardPlanner.Candidate {
        ContentDiscardPlanner.Candidate(key: key, kind: kind, hiddenFor: hiddenFor)
    }

    @Test func protectedContentNeverGoesForTheTimeoutOrPressureButGoesWhenThePersonAsks() {
        var pinned = page()
        pinned.isPinned = true
        for reason in [DiscardReason.proactive, .urgent, .crashedSubframe] {
            let eligibility = planner.eligibility(of: pinned, setting: setting, for: reason)
            #expect(eligibility.result == .protected)
            #expect(eligibility.reason == .pinned)
        }
        #expect(planner.eligibility(of: pinned, setting: setting, for: .external).result == .eligible)
    }

    @Test func disallowedContentStaysEvenWhenThePersonAsks() {
        var result = page()
        result.showsFormSubmission = true
        for reason in DiscardReason.allCases {
            #expect(planner.eligibility(of: result, setting: setting, for: reason).result == .disallowed)
        }
        var unrestorable = page()
        unrestorable.canRestore = false
        #expect(planner.eligibility(of: unrestorable, setting: setting, for: .external).reason == .unsupported)
    }

    @Test func theWorstResultWinsAndEveryReasonIsListedInRuleOrder() {
        var page = page()
        page.isPinned = true
        page.hasDevTools = true
        page.canRestore = false
        let eligibility = planner.eligibility(of: page, setting: setting, for: .urgent)
        #expect(eligibility.result == .disallowed)
        #expect(eligibility.reasons == [.unsupported, .devTools, .pinned])
        #expect(eligibility.reason == .unsupported)
    }

    @Test func notificationsProtectOnlyFromTheTimeout() {
        var page = page()
        page.allowsNotifications = true
        #expect(planner.eligibility(of: page, setting: setting, for: .proactive).reason == .notifications)
        #expect(planner.eligibility(of: page, setting: setting, for: .urgent).result == .eligible)
        #expect(planner.eligibility(of: page, setting: setting, for: .frozenWithGrowingMemory).result == .eligible)
    }

    @Test func theLeadRuleKeepsWhatThePersonWouldLoseFromEveryDiscardButTheirOwn() {
        let facts: [(CannotDiscardReason, (inout ContentDiscardPlanner.Candidate) -> Void)] = [
            (.capturing, { $0.isCapturing = true }),
            (.downloading, { $0.isDownloading = true }),
            (.agentLease, { $0.hasAgentLease = true }),
            (.unsavedEdits, { $0.hasUnsavedEdits = true }),
            (.runningCommand, { $0.runsCommand = true }),
            (.audio, { $0.isAudible = true }),
            (.formInput, { $0.hasFormInput = true }),
            (.unreadableFrame, { $0.hasUnreadableFrame = true }),
            (.beforeUnload, { $0.asksBeforeUnload = true }),
            (.webRTC, { $0.hasWebRTC = true }),
            (.connectedDevice, { $0.hasConnectedDevice = true }),
            (.webAudio, { $0.usesWebAudio = true }),
            (.unanswered, { $0.isUnanswered = true; $0.isDoubted = true }),
        ]
        for (reason, apply) in facts {
            var candidate = page(kind: .terminalSurface)
            apply(&candidate)
            for discard in [DiscardReason.proactive, .urgent, .frozenWithGrowingMemory, .crashedSubframe] {
                let eligibility = planner.eligibility(of: candidate, setting: setting, for: discard)
                #expect(eligibility.result == .protected, "\(reason) at \(discard)")
                #expect(eligibility.reason == reason)
            }
            #expect(planner.eligibility(of: candidate, setting: setting, for: .external).result == .eligible, "\(reason)")
        }
    }

    @Test func everyKindPlansThroughTheSameRules() {
        var editor = page("editor", kind: .internalPage)
        editor.hasUnsavedEdits = true
        var shell = page("shell", kind: .terminalSurface)
        shell.runsCommand = true
        let idle = page("idle", kind: .sidebarSection)
        let plan = planner.plan(setting, for: .proactive, threshold: 600, pace: timeoutPace, candidates: [editor, shell, idle])
        #expect(plan.due == ["idle"])
        #expect(plan.exemptions == ["editor": .unsavedEdits, "shell": .runningCommand])
    }

    /// Chrome's `kDiscardAttempted` (discard_eligibility_policy.cc): content whose discard was tried
    /// and did not finish is disallowed for every kind and every discard, the person's own too.
    @Test func aFailedDiscardIsDisallowedForEveryKindAndEveryDiscard() {
        for kind in ContentKind.allCases {
            var candidate = page(kind: kind)
            candidate.discardAttempted = true
            for reason in DiscardReason.allCases {
                let eligibility = planner.eligibility(of: candidate, setting: setting, for: reason)
                #expect(eligibility.result == .disallowed, "\(kind) at \(reason)")
                #expect(eligibility.reasons == [.discardAttempted], "\(kind) at \(reason)")
            }
        }
    }

    /// After a failed discard the planner keeps that key until it shows, and the next candidate
    /// takes its slot in the same pass.
    @Test func aFailedDiscardGivesItsSlotToTheNextCandidateUntilItShows() {
        let candidates = [page("first", hiddenFor: 9_000), page("second", hiddenFor: 8_000), page("third", hiddenFor: 7_000)]
        let pace = ContentDiscardPlanner.Pace(perPass: 1, interval: 5, minimumHidden: 0)
        #expect(planner.plan(setting, for: .urgent, threshold: 600, pace: pace, candidates: candidates).due == ["first"])

        var attempts = ContentDiscardPlanner.AttemptMarkers()
        attempts.mark("first")
        func marked() -> [ContentDiscardPlanner.Candidate] {
            candidates.map { candidate in
                var candidate = candidate
                candidate.discardAttempted = attempts.contains(candidate.key)
                return candidate
            }
        }
        for reason in [DiscardReason.proactive, .urgent] {
            let plan = planner.plan(setting, for: reason, threshold: 600, pace: pace, candidates: marked())
            #expect(plan.due == ["second"], "\(reason)")
            #expect(plan.exemptions == ["first": .discardAttempted], "\(reason)")
        }

        attempts.clear("first")
        #expect(!attempts.contains("first"))
        #expect(planner.plan(setting, for: .urgent, threshold: 600, pace: pace, candidates: marked()).due == ["first"],
                "once shown, it may go again")
    }

    /// The marker keeps the content even when nothing else would come due: it is no deadline the
    /// planner waits for, only the next show ends it.
    @Test func aFailedDiscardSetsNoDeadline() {
        var failed = page("failed")
        failed.discardAttempted = true
        let plan = planner.plan(setting, for: .proactive, threshold: 600, pace: timeoutPace, candidates: [failed])
        #expect(plan.due.isEmpty)
        #expect(plan.nextCheck == nil)
        #expect(planner.eligibility(of: failed, setting: setting, for: .proactive).endsIn == nil)
    }

    @Test func urgentPlansTakeTheLeastValuableOldEnoughContentBeforeItsTimeout() {
        let young = page("young", hiddenFor: 5)
        let old = page("old", hiddenFor: 120)
        let pace = ContentDiscardPlanner.Pace(perPass: 3, interval: 3, minimumHidden: 10)
        let plan = planner.plan(setting, for: .urgent, threshold: 600, pace: pace, candidates: [young, old])
        #expect(plan.due == ["old"])
        #expect(plan.nextCheck == pace.interval)
        #expect(planner.plan(setting, for: .proactive, threshold: 600, pace: timeoutPace, candidates: [young, old]).due.isEmpty)
    }

    /// New kinds take Chrome's urgent pace: one discard per pass, the next look 5 s later.
    @Test func chromesUrgentPaceTakesOneAndLooksAgainInFiveSeconds() {
        let pace = ContentDiscardPlanner.Pace.chromeUrgent
        #expect(pace == ContentDiscardPlanner.Pace(perPass: 1, interval: 5, minimumHidden: 0))
        let hidden = (0..<4).map { page("s\($0)", kind: .sidebarSection, hiddenFor: Double(60 * ($0 + 1))) }
        let plan = planner.plan(setting, for: .urgent, threshold: 600, pace: pace, candidates: hidden)
        #expect(plan.due == ["s3"], "the least valuable section goes first, alone")
        #expect(plan.nextCheck == 5)
    }

    /// The browser's paces stay on the browser's planner (p07-memory.md section 3.C, until task 114).
    @Test func theBrowserKeepsItsOwnPaces() {
        #expect(HibernationPlanner.pace(at: .normal) == ContentDiscardPlanner.Pace(perPass: 2, interval: 5, minimumHidden: 0))
        #expect(HibernationPlanner.pace(at: .warning) == ContentDiscardPlanner.Pace(perPass: 1, interval: 15, minimumHidden: 60))
        #expect(HibernationPlanner.pace(at: .critical) == ContentDiscardPlanner.Pace(perPass: 3, interval: 3, minimumHidden: 10))
        #expect(HibernationPlanner.pace(at: .critical) != ContentDiscardPlanner.Pace.chromeUrgent)
    }

    /// `browser.hibernation` is the browser's policy: off, a Never Hibernate host or the pinned rule
    /// keeps browser pages only. A terminal, a conversation or a sidebar section still goes.
    @Test func theBrowsersSettingKeepsOnlyBrowserPages() {
        let off = BrowserHibernationSetting(mode: .off)
        let excluding = BrowserHibernationSetting(mode: .moderate, exclusions: ["example.com"])
        for kind in ContentKind.allCases where kind != .browser {
            var candidate = page(kind: kind)
            candidate.host = "example.com"
            candidate.isPinned = true
            candidate.allowsNotifications = true
            candidate.isNeighbor = true
            candidate.isAgentDriving = true
            candidate.showsFormSubmission = true
            for reason in DiscardReason.allCases {
                #expect(planner.eligibility(of: candidate, setting: off, for: reason).result == .eligible, "\(kind) at \(reason), off")
                #expect(planner.eligibility(of: candidate, setting: excluding, for: reason).result == .eligible, "\(kind) at \(reason)")
            }
        }
        var terminal = page("shell", kind: .terminalSurface)
        terminal.host = "example.com"
        let plan = planner.plan(off, for: .proactive, threshold: 600, pace: timeoutPace, candidates: [terminal, page("web")])
        #expect(plan.due == ["shell"])
        #expect(plan.exemptions == ["web": .disabled])
        var browser = page()
        browser.host = "example.com"
        #expect(planner.eligibility(of: browser, setting: excluding, for: .urgent).reason == .excluded)
    }

    /// The person's Hibernate Tab is Chrome's external discard: every disallowed rule refuses it,
    /// no protected rule does.
    @Test func hibernateTabIsRefusedOnlyByDisallowedRules() {
        let facts: [(CannotDiscardReason, (inout ContentDiscardPlanner.Candidate) -> Void)] = [
            (.unsupported, { $0.canRestore = false }),
            (.formSubmission, { $0.showsFormSubmission = true }),
            (.discardAttempted, { $0.discardAttempted = true }),
        ]
        let disallowed = DiscardRule.registered.filter { $0.result == .disallowed }.map(\.reason)
        #expect(Set(disallowed) == Set(facts.map(\.0)), "a disallowed rule has no Hibernate Tab case here")
        for (reason, apply) in facts {
            var candidate = page()
            apply(&candidate)
            #expect(HibernationPlanner.hibernateTabRefusal(candidate, setting: setting) == reason)
        }
        var kept = page()
        kept.isPinned = true
        kept.hasDevTools = true
        kept.isCapturing = true
        kept.isDownloading = true
        kept.hasAgentLease = true
        kept.isNeighbor = true
        kept.isAgentDriving = true
        kept.allowsNotifications = true
        kept.host = "example.com"
        kept.isAudible = true
        kept.hasFormInput = true
        kept.asksBeforeUnload = true
        kept.isUnanswered = true
        kept.isDoubted = true
        let excluding = BrowserHibernationSetting(mode: .off, exclusions: ["example.com"])
        #expect(planner.eligibility(of: kept, setting: excluding, for: .urgent).result == .protected)
        #expect(HibernationPlanner.hibernateTabRefusal(kept, setting: excluding) == nil)
        for rule in DiscardRule.registered {
            #expect(rule.discardReasons.contains(.external) == (rule.result == .disallowed), "\(rule.reason)")
        }
    }

    /// The probe fills the lead rule's facts and the rules decide, in the probe's order.
    @Test func theProbesAnswerIsDecidedByTheRules() {
        var facts = page()
        PageProbe(playingMedia: true, editedForm: true, webAudio: true).fill(&facts)
        #expect(facts.isAudible && facts.hasFormInput && facts.usesWebAudio)
        #expect(planner.eligibility(of: facts, setting: setting, for: .urgent).reasons == [.audio, .formInput, .webAudio])
        #expect(PageProbe(playingMedia: true, capturing: true).exemption == .capturing)
        var unanswered = page()
        PageProbe(answered: false).fill(&unanswered)
        #expect(planner.eligibility(of: unanswered, setting: setting, for: .proactive).reason == .unanswered)
        #expect(planner.eligibility(of: unanswered, setting: setting, for: .urgent).result == .eligible, "no doubt left")
        unanswered.isDoubted = true
        #expect(planner.eligibility(of: unanswered, setting: setting, for: .urgent).reason == .unanswered)
    }

    @Test func eachRegisteredRuleHasItsOwnReason() {
        let reasons = DiscardRule.registered.map(\.reason)
        #expect(Set(reasons).count == reasons.count)
        for rule in DiscardRule.registered {
            #expect(rule.result != .eligible, "\(rule.reason) keeps nothing")
            #expect(!rule.discardReasons.isEmpty, "\(rule.reason) applies to no discard")
        }
    }

    /// The 30 enumerators of Chrome's chrome/browser/performance_manager/policies/cannot_discard_reason.h.
    static let chromeReasons = [
        "kNotATab", "kAlreadyDiscarded", "kDiscardAttempted", "kNoMainFrame", "kVisible", "kAudible",
        "kRecentlyAudible", "kRecentlyVisible", "kPictureInPicture", "kPdf", "kNotWebOrInternal", "kInvalidURL",
        "kOptedOut", "kNotificationsEnabled", "kExtensionProtected", "kCapturingVideo", "kCapturingAudio",
        "kCapturingWindow", "kCapturingDisplay", "kBeingMirrored", "kConnectedToBluetooth", "kConnectedToUSB",
        "kActiveTab", "kPinnedTab", "kDevToolsOpen", "kBackgroundActivity", "kFormInteractions", "kUserEdits",
        "kGlicShared", "kWebApp",
    ]

    @Test func everyChromeReasonMapsToACase() {
        #expect(Self.chromeReasons.count == 30)
        for name in Self.chromeReasons {
            #expect(CannotDiscardReason(chromeReason: name) != nil, "\(name)")
        }
        #expect(CannotDiscardReason(chromeReason: "kNotAReason") == nil)
        #expect(CannotDiscardReason(chromeReason: "kPinnedTab") == .pinned)
        #expect(CannotDiscardReason(chromeReason: "kUserEdits") == .unsavedEdits)
    }

    /// `debug.surfaces` reported these raw values before the planner; scripts and benches read them.
    @Test func theRawValuesDebugSurfacesReportedStayTheSame() {
        let reported: [CannotDiscardReason: String] = [
            .disabled: "disabled", .excluded: "excluded", .pinned: "pinned", .devTools: "devtools",
            .capturing: "capturing", .unsupported: "unsupported", .audio: "audio", .formInput: "form_input",
            .webAudio: "web_audio", .beforeUnload: "before_unload", .webRTC: "web_rtc",
            .connectedDevice: "connected_device", .unreadableFrame: "unreadable_frame",
            .notifications: "notifications", .agentBusy: "agent_busy", .agentTurnsUnknown: "agent_turns_unknown",
            .formSubmission: "form_submission", .agentDriving: "agent_driving", .neighbor: "neighbor",
            .unanswered: "unanswered", .downloading: "downloading", .agentLease: "agent_lease",
        ]
        #expect(reported.count == 22)
        for (reason, raw) in reported {
            #expect(reason.rawValue == raw)
        }
        #expect(Set(CannotDiscardReason.allCases.map(\.rawValue)).count == CannotDiscardReason.allCases.count)
    }
}
