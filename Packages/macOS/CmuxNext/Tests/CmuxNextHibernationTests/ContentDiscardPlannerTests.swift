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

    func page(_ key: String = "p", kind: ContentKind = .browser, hiddenFor: Double = 7_200) -> ContentDiscardPlanner.Candidate {
        ContentDiscardPlanner.Candidate(key: key, kind: kind, hiddenFor: hiddenFor)
    }

    @Test func protectedContentNeverGoesForTheTimeoutOrPressureButGoesWhenThePersonAsks() {
        var pinned = page()
        pinned.isPinned = true
        for reason in [DiscardReason.proactive, .urgent] {
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
        ]
        for (reason, apply) in facts {
            var candidate = page(kind: .terminalSurface)
            apply(&candidate)
            for discard in [DiscardReason.proactive, .urgent, .frozenWithGrowingMemory] {
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
        let plan = planner.plan(setting, for: .proactive, threshold: 600, pace: .normal, candidates: [editor, shell, idle])
        #expect(plan.due == ["idle"])
        #expect(plan.exemptions == ["editor": .unsavedEdits, "shell": .runningCommand])
    }

    @Test func urgentPlansTakeTheLeastValuableOldEnoughContentBeforeItsTimeout() {
        let young = page("young", hiddenFor: 5)
        let old = page("old", hiddenFor: 120)
        let plan = planner.plan(setting, for: .urgent, threshold: 600, pace: .critical, candidates: [young, old])
        #expect(plan.due == ["old"])
        #expect(plan.nextCheck == ContentDiscardPlanner.Pace.critical.interval)
        #expect(planner.plan(setting, for: .proactive, threshold: 600, pace: .normal, candidates: [young, old]).due.isEmpty)
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
