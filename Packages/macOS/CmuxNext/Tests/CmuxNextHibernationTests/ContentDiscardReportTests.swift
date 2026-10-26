import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextSettings
import Testing

/// ``ContentDiscardReport``, the rows of `debug.discards` (p07-memory task 011): cmux's
/// chrome://discards. Each of the nine content kinds is listed, every row that is not eligible says
/// why, and a planner pass's verdicts come from that pass only.
@Suite struct ContentDiscardReportTests {
    let start = ContinuousClock.now

    /// One hidden content of each kind with a different verdict, and one shown sidebar section.
    func reportWithEveryKind() -> ContentDiscardReport {
        var report = ContentDiscardReport(tracking: .browser, .agentPage)
        let verdicts: [ContentKind: DiscardEligibility] = [
            .browser: DiscardEligibility(),
            .agentPage: DiscardEligibility(keptFor: .agentBusy),
            .internalPage: DiscardEligibility(keptFor: .unsavedEdits),
            .topPage: DiscardEligibility(),
            .conversation: DiscardEligibility(keptFor: .recentlyVisible),
            .terminalSurface: DiscardEligibility(keptFor: .runningCommand),
            .parkedWorkspace: DiscardEligibility(),
            .overlayPage: DiscardEligibility(keptFor: .unsupported),
        ]
        for (kind, verdict) in verdicts {
            report.note(.hidden(kind.rawValue, kind), at: start)
            report.note(.planned(kind.rawValue, kind, hiddenFor: 90, verdict), at: start + .seconds(90))
        }
        report.note(.shown(ContentKind.sidebarSection.rawValue, .sidebarSection), at: start)
        return report
    }

    @Test func rowsOfEveryKindCarryTheirColumnsAndEveryNonEligibleRowHasAReason() throws {
        let json = reportWithEveryKind().report(now: start + .seconds(100))
        let rows = try #require(json["contents"].flatMap(Self.array))
        #expect(Set(rows.compactMap { $0["kind"]?.stringValue }) == Set(ContentKind.allCases.map(\.rawValue)))
        for row in rows {
            let eligibility = try #require(row["eligibility"]?.stringValue)
            if eligibility == "eligible" {
                #expect(row["reason"] == .null, "an eligible row has a reason: \(row)")
            } else {
                #expect(row["reason"]?.stringValue?.isEmpty == false, "a \(eligibility) row has no reason: \(row)")
            }
            guard case .object(let fields) = row else { Issue.record("row \(row) is no object"); continue }
            #expect(Set(fields.keys) == ["key", "kind", "visible", "hidden_for", "state", "eligibility", "reason", "reasons",
                                         "last_discard_reason", "wake_count"])
        }
        let sidebar = try #require(rows.first { $0["kind"] == "sidebar_section" })
        #expect(sidebar["visible"] == true)
        #expect(sidebar["hidden_for"] == .null)
        #expect(sidebar["eligibility"] == "protected")
        #expect(sidebar["reason"] == "visible")
        let browser = try #require(rows.first { $0["kind"] == "browser" })
        #expect(browser["hidden_for"] == 100, "hidden_for counts from the owner's 90 s, then 10 s more")
        #expect(browser["state"] == "live")
        let overlay = try #require(rows.first { $0["kind"] == "overlay_page" })
        #expect(overlay["eligibility"] == "disallowed", "the unsupported rule keeps content from every discard")
        #expect(overlay["reason"] == "unsupported")
    }

    @Test func kindsNoOwnerReportsAreListedAsNotATab() throws {
        let json = ContentDiscardReport(tracking: .browser, .agentPage).report(now: start)
        let kinds = try #require(json["kinds"].flatMap(Self.array))
        #expect(kinds.compactMap { $0["kind"]?.stringValue } == ContentKind.allCases.map(\.rawValue))
        for kind in kinds {
            let tracked = kind["tracked"] == true
            #expect(tracked == ["browser", "agent_page"].contains(kind["kind"]?.stringValue ?? ""))
            #expect(kind["reason"] == (tracked ? JSONValue.null : JSONValue.string("not_a_tab")), "\(kind)")
        }
    }

    @Test func aDiscardRecordsItsReasonAndAWakeCountsOnce() throws {
        var report = ContentDiscardReport(tracking: .browser)
        report.note(.hidden("tab", .browser), at: start)
        report.note(.planned("tab", .browser, hiddenFor: 1_800, DiscardEligibility()), at: start)
        report.note(.frozen("tab", true), at: start)
        #expect(report.row("tab", now: start)?.state == .frozen)
        report.note(.discarding("tab", .browser, .urgent), at: start)
        report.note(.discarded("tab"), at: start)
        var row = try #require(report.row("tab", now: start))
        #expect(row.state == .discarded)
        #expect(row.eligibility == DiscardEligibility(result: .disallowed, reasons: [.alreadyDiscarded]))
        #expect(row.lastDiscardReason == .urgent)
        #expect(row.wakeCount == 0)
        report.note(.frozen("tab", false), at: start)
        #expect(report.row("tab", now: start)?.state == .discarded, "a thaw woke a discarded page")

        report.note(.woke("tab"), at: start)
        report.note(.woke("tab"), at: start)
        report.note(.shown("tab", .browser), at: start)
        row = try #require(report.row("tab", now: start))
        #expect(row.state == .live)
        #expect(row.wakeCount == 1, "a second wake of a live page counted")
        #expect(row.lastDiscardReason == .urgent, "the last discard's reason went with the wake")
        #expect(row.eligibility == DiscardEligibility(result: .protected, reasons: [.visible]))
        #expect(row.json["last_discard_reason"] == "urgent")
        #expect(row.json["wake_count"] == 1)
        report.note(.removed("tab"), at: start)
        #expect(report.rows(now: start).isEmpty)
    }

    /// Discarded content that shows was rebuilt to show (an agent page): one wake, no separate event.
    @Test func showingDiscardedContentCountsOneWake() throws {
        var report = ContentDiscardReport(tracking: .agentPage)
        report.note(.hidden("chat", .agentPage), at: start)
        report.note(.discarding("chat", .agentPage, .proactive), at: start)
        report.note(.discarded("chat"), at: start)
        report.note(.shown("chat", .agentPage), at: start)
        report.note(.shown("chat", .agentPage), at: start)
        let row = try #require(report.row("chat", now: start))
        #expect(row.state == .live && row.visible)
        #expect(row.wakeCount == 1, "a second show of a live page counted a wake")
        #expect(row.lastDiscardReason == .proactive)
    }

    /// A discard that never finished (its page was kept or shown first) does not name the next one.
    @Test func aShowDropsAnUnfinishedDiscardsReason() {
        var report = ContentDiscardReport(tracking: .browser)
        report.note(.hidden("tab", .browser), at: start)
        report.note(.discarding("tab", .browser, .external), at: start)
        report.note(.shown("tab", .browser), at: start)
        report.note(.hidden("tab", .browser), at: start)
        report.note(.discarded("tab"), at: start)
        #expect(report.row("tab", now: start)?.lastDiscardReason == nil)
    }

    @Test func aHiddenContentNoOwnerJudgedYetIsProtectedAsRecentlyVisible() {
        var report = ContentDiscardReport(tracking: .browser)
        report.note(.hidden("tab", .browser), at: start)
        let unjudged = DiscardEligibility(result: .protected, reasons: [.recentlyVisible])
        #expect(report.row("tab", now: start + .seconds(5))?.eligibility == unjudged)
        #expect(report.row("tab", now: start + .seconds(5))?.hiddenFor == 5)
        report.note(.planned("tab", .browser, hiddenFor: 5, DiscardEligibility(keptFor: .pinned)), at: start + .seconds(5))
        report.note(.shown("tab", .browser), at: start + .seconds(6))
        report.note(.hidden("tab", .browser), at: start + .seconds(7))
        #expect(report.row("tab", now: start + .seconds(7))?.eligibility == unjudged, "a verdict from before the show still applied")
    }

    /// A kept content is as strongly kept as its rule: only what the person's Hibernate Tab
    /// refuses is disallowed; a reason no rule has (the probe's, the neighbor tabs') protects.
    @Test func keptContentTakesItsRulesResult() {
        #expect(DiscardEligibility(keptFor: .unsupported).result == .disallowed)
        #expect(DiscardEligibility(keptFor: .formSubmission).result == .disallowed)
        for reason in [CannotDiscardReason.disabled, .pinned, .notifications, .agentLease, .audio, .formInput, .neighbor,
                       .agentDriving, .unanswered, .beforeUnload] {
            #expect(DiscardEligibility(keptFor: reason) == DiscardEligibility(result: .protected, reasons: [reason]))
        }
    }

    @Test func theKindParameterKeepsOneKindAndRejectsAnUnknownOne() throws {
        let report = reportWithEveryKind()
        let json = report.report(["kind": "terminal_surface"], now: start + .seconds(90))
        let rows = try #require(json["contents"].flatMap(Self.array))
        #expect(rows.count == 1)
        #expect(rows.first?["reason"] == "running_command")
        #expect(json["kinds"].flatMap(Self.array)?.count == 1)
        let refused = report.report(["kind": "tab"], now: start)
        #expect(refused["error"]?.stringValue?.contains("sidebar_section") == true)
    }

    // MARK: A pass's verdicts

    func page(_ key: String = "p", hiddenFor: Double = 7_200) -> ContentDiscardPlanner.Candidate {
        ContentDiscardPlanner.Candidate(key: key, hiddenFor: hiddenFor)
    }

    func pass(_ setting: BrowserHibernationSetting, _ pressure: MemoryPressureLevel, _ candidates: [ContentDiscardPlanner.Candidate],
              probeKept: [String: CannotDiscardReason] = [:], into report: inout ContentDiscardReport) {
        let plan = HibernationPlanner.plan(setting, pressure: pressure, candidates: candidates)
        report.notePass(plan, candidates: candidates, probeKept: probeKept, at: start)
    }

    /// Hibernation off keeps every page as disabled; turned on, the next pass makes the page
    /// eligible, though no show or close came between.
    @Test func turningHibernationOnMakesTheNextPassEligible() {
        var report = ContentDiscardReport(tracking: .browser)
        pass(BrowserHibernationSetting(mode: .off), .normal, [page()], into: &report)
        #expect(report.row("p", now: start)?.eligibility == DiscardEligibility(keptFor: .disabled))
        pass(.fallback, .normal, [page()], into: &report)
        #expect(report.row("p", now: start)?.eligibility == DiscardEligibility())
    }

    /// Notifications keep a page from the timeout only (Chrome's kNotificationsEnabled): at critical
    /// pressure the same page is eligible.
    @Test func notificationsProtectAtNormalPressureOnly() {
        var report = ContentDiscardReport(tracking: .browser)
        var notifying = page()
        notifying.allowsNotifications = true
        pass(.fallback, .normal, [notifying], into: &report)
        #expect(report.row("p", now: start)?.eligibility == DiscardEligibility(keptFor: .notifications))
        pass(.fallback, .critical, [notifying], into: &report)
        #expect(report.row("p", now: start)?.eligibility == DiscardEligibility())
    }

    /// A page the probe kept lately keeps the probe's reason while others go first, and is eligible
    /// once it is due again (the probe asks it again).
    @Test func aPageTheProbeKeptLatelyKeepsItsReasonUntilItIsDueAgain() throws {
        var report = ContentDiscardReport(tracking: .browser)
        var kept = page("kept", hiddenFor: 600)
        kept.recentlyKept = true
        let other = page("other", hiddenFor: 600)
        let plan = HibernationPlanner.plan(.fallback, pressure: .warning, candidates: [kept, other])
        try #require(plan.due == ["other"], "the probe's page should rank after the others")
        report.notePass(plan, candidates: [kept, other], probeKept: ["kept": .audio], at: start)
        #expect(report.row("kept", now: start)?.eligibility == DiscardEligibility(keptFor: .audio))
        #expect(report.row("other", now: start)?.eligibility == DiscardEligibility())

        pass(.fallback, .warning, [kept], probeKept: ["kept": .audio], into: &report)
        #expect(report.row("kept", now: start)?.eligibility == DiscardEligibility(), "a due page is eligible: the probe asks it again")
    }

    private static func array(_ value: JSONValue) -> [JSONValue]? {
        if case .array(let items) = value { return items }
        return nil
    }
}
