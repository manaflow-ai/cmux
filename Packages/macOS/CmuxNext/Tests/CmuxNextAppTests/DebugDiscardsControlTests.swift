import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextSettings
import Foundation
import Testing

/// `debug.discards` (p07-memory task 011): cmux's chrome://discards. Every one of the nine content
/// kinds is listed; every content that cannot be discarded says why; the rows come from what the
/// planner's owners last reported (kind, visible, hidden_for, state, eligibility and reason, last
/// discard reason, wake count).
@MainActor @Suite(.serialized)
struct DebugDiscardsControlTests {
    let start = ContinuousClock.now

    /// One hidden content of every kind, each with a different verdict, and one shown.
    func plannerWithEveryKind() -> ContentDiscardPlanner {
        var planner = ContentDiscardPlanner(tracking: .browser, .agentPage)
        for kind in ContentKind.allCases { planner.track(kind) }
        let verdicts: [ContentKind: CanDiscardResult] = [
            .browser: .eligible,
            .agentPage: .protected(.agentBusy),
            .internalPage: .protected(.unsavedEdits),
            .topPage: .eligible,
            .conversation: .protected(.recentlyVisible),
            .terminalSurface: .protected(.runningCommand),
            .parkedWorkspace: .eligible,
            .overlayPage: .disallowed(.unsupported),
        ]
        for (kind, verdict) in verdicts {
            planner.note(.hidden(kind.rawValue, kind), at: start)
            planner.note(.planned(kind.rawValue, kind, hiddenFor: 90, verdict), at: start + .seconds(90))
        }
        planner.note(.shown(ContentKind.sidebarSection.rawValue, .sidebarSection), at: start)
        return planner
    }

    @Test func everyKindHasARowAndEveryNonEligibleRowHasAReason() throws {
        let report = plannerWithEveryKind().report(now: start + .seconds(100))
        let rows = try #require(report["contents"].flatMap(Self.array))
        #expect(Set(rows.compactMap { $0["kind"]?.stringValue }) == Set(ContentKind.allCases.map(\.rawValue)))
        for row in rows {
            let eligibility = try #require(row["eligibility"]?.stringValue)
            if eligibility == "eligible" {
                #expect(row["reason"] == .null, "an eligible row has a reason: \(row)")
            } else {
                #expect(row["reason"]?.stringValue?.isEmpty == false, "a \(eligibility) row has no reason: \(row)")
            }
            guard case .object(let fields) = row else { Issue.record("row \(row) is no object"); continue }
            #expect(Set(fields.keys) == ["key", "kind", "visible", "hidden_for", "state", "eligibility", "reason", "last_discard_reason", "wake_count"])
        }
        let sidebar = try #require(rows.first { $0["kind"] == "sidebar_section" })
        #expect(sidebar["visible"] == true)
        #expect(sidebar["hidden_for"] == .null)
        #expect(sidebar["eligibility"] == "protected")
        #expect(sidebar["reason"] == "visible")
        let browser = try #require(rows.first { $0["kind"] == "browser" })
        #expect(browser["hidden_for"] == 100, "hidden_for counts from the planner's 90 s, then 10 s more")
        #expect(browser["state"] == "live")
        let overlay = try #require(rows.first { $0["kind"] == "overlay_page" })
        #expect(overlay["eligibility"] == "disallowed")
        #expect(overlay["reason"] == "unsupported")
    }

    @Test func kindsNoOwnerReportsAreListedWithNoPolicy() throws {
        let planner = ContentDiscardPlanner(tracking: .browser, .agentPage)
        let report = planner.report(now: start)
        let kinds = try #require(report["kinds"].flatMap(Self.array))
        #expect(kinds.compactMap { $0["kind"]?.stringValue } == ContentKind.allCases.map(\.rawValue))
        for kind in kinds {
            let tracked = kind["tracked"] == true
            #expect(tracked == ["browser", "agent_page"].contains(kind["kind"]?.stringValue ?? ""))
            #expect(kind["reason"] == (tracked ? JSONValue.null : JSONValue.string("no_policy")), "\(kind)")
        }
    }

    @Test func aDiscardRecordsItsReasonAndAWakeCountsOnce() throws {
        var planner = ContentDiscardPlanner(tracking: .browser)
        planner.note(.hidden("tab", .browser), at: start)
        planner.note(.planned("tab", .browser, hiddenFor: 1_800, .eligible), at: start)
        planner.note(.frozen("tab", true), at: start)
        #expect(planner.row("tab", now: start)?.state == .frozen)
        planner.note(.discarding("tab", .browser, DiscardReason(pressure: .critical, user: false)), at: start)
        planner.note(.discarded("tab"), at: start)
        var row = try #require(planner.row("tab", now: start))
        #expect(row.state == .discarded)
        #expect(row.eligibility == .disallowed(.alreadyDiscarded))
        #expect(row.lastDiscardReason == .urgent)
        #expect(row.wakeCount == 0)
        planner.note(.frozen("tab", false), at: start)
        #expect(planner.row("tab", now: start)?.state == .discarded, "a thaw woke a discarded page")

        planner.note(.woke("tab"), at: start)
        planner.note(.woke("tab"), at: start)
        planner.note(.shown("tab", .browser), at: start)
        row = try #require(planner.row("tab", now: start))
        #expect(row.state == .live)
        #expect(row.wakeCount == 1, "a second wake of a live page counted")
        #expect(row.lastDiscardReason == .urgent, "the last discard's reason went with the wake")
        #expect(row.eligibility == .protected(.visible))

        let json = row.json
        #expect(json["last_discard_reason"] == "urgent")
        #expect(json["wake_count"] == 1)
        planner.note(.removed("tab"), at: start)
        #expect(planner.rows(now: start).isEmpty)
    }

    @Test func aHiddenContentNoPassJudgedIsProtectedAsNotPlanned() {
        var planner = ContentDiscardPlanner(tracking: .browser)
        planner.note(.hidden("tab", .browser), at: start)
        #expect(planner.row("tab", now: start + .seconds(5))?.eligibility == .protected(.notPlanned))
        #expect(planner.row("tab", now: start + .seconds(5))?.hiddenFor == 5)
        planner.note(.planned("tab", .browser, hiddenFor: 5, .protected(.pinnedTab)), at: start + .seconds(5))
        planner.note(.shown("tab", .browser), at: start + .seconds(6))
        planner.note(.hidden("tab", .browser), at: start + .seconds(7))
        #expect(planner.row("tab", now: start + .seconds(7))?.eligibility == .protected(.notPlanned),
                "a verdict from before the show still applied")
    }

    @Test func discardReasonsFollowPressureAndThePerson() {
        #expect(DiscardReason(pressure: .normal, user: false) == .proactive)
        #expect(DiscardReason(pressure: .warning, user: false) == .urgent)
        #expect(DiscardReason(pressure: .critical, user: false) == .urgent)
        #expect(DiscardReason(pressure: .critical, user: true) == .external)
    }

    /// Only what `BrowserHibernation.hibernateNow` refuses is disallowed; the person's Hibernate Tab
    /// takes every other exempt page, so those are protected. Chrome's name where Chrome has the reason.
    @Test func exemptionsMapToChromeReasonsAndResults() {
        let all: [HibernationPlanner.Exemption] = [
            .disabled, .excluded, .pinned, .devTools, .capturing, .unsupported, .audio, .formInput, .webAudio,
            .beforeUnload, .webRTC, .connectedDevice, .unreadableFrame, .notifications, .agentBusy, .agentTurnsUnknown,
            .formSubmission, .agentDriving, .neighbor, .unanswered, .downloading, .agentLease,
        ]
        for exemption in all {
            let result = CanDiscardResult(exemption)
            if exemption == .unsupported || exemption == .formSubmission {
                #expect(result == .disallowed(CannotDiscardReason(exemption)))
            } else {
                #expect(result == .protected(CannotDiscardReason(exemption)))
            }
        }
        #expect(CannotDiscardReason(.excluded) == .optedOut)
        #expect(CannotDiscardReason(.pinned) == .pinnedTab)
        #expect(CannotDiscardReason(.devTools) == .devToolsOpen)
        #expect(CannotDiscardReason(.audio) == .audible)
        #expect(CannotDiscardReason(.formInput) == .formInteractions)
        #expect(CannotDiscardReason(.notifications) == .notificationsEnabled)
        // An exemption with no Chrome reason keeps the name debug.surfaces shows.
        #expect(CannotDiscardReason(.agentLease).rawValue == HibernationPlanner.Exemption.agentLease.rawValue)
        #expect(CannotDiscardReason(.unreadableFrame).rawValue == HibernationPlanner.Exemption.unreadableFrame.rawValue)
    }

    @Test func theKindParameterKeepsOneKindAndRejectsAnUnknownOne() throws {
        let planner = plannerWithEveryKind()
        let report = planner.report(["kind": "terminal_surface"], now: start + .seconds(90))
        let rows = try #require(report["contents"].flatMap(Self.array))
        #expect(rows.count == 1)
        #expect(rows.first?["reason"] == "running_command")
        #expect(report["kinds"].flatMap(Self.array)?.count == 1)
        let refused = planner.report(["kind": "tab"], now: start)
        #expect(refused["error"]?.stringValue?.contains("sidebar_section") == true)
    }

    /// The app's owners report: BrowserHibernation tracks browser pages, and its agent page
    /// hibernation reports into the same planner.
    @Test func browserHibernationTracksBrowserAndAgentPages() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let hibernation = BrowserHibernation(cache: services.cache, memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
                                             lowPower: LowPowerMode(enabled: false))
        #expect(hibernation.discards.trackedKinds == [.browser])
        let agentPages = AgentPageHibernation(tabs: { nil })
        hibernation.agentPages = agentPages
        #expect(hibernation.discards.trackedKinds == [.browser, .agentPage])
        agentPages.noteDiscard(.hidden("tab_chat", .agentPage))
        #expect(hibernation.discards.row("tab_chat", now: .now)?.kind == .agentPage)
        withExtendedLifetime((services, hibernation)) {}
    }

    /// A real agent page through AgentPageHibernation: kept while its agent works, released when
    /// due (proactive), and one wake once its tab builds the page again.
    @Test func agentPageHibernationReportsVerdictsDiscardsAndWakes() async throws {
        let rig = AgentPageHibernationTests.Rig()
        let box = PlannerBox()
        rig.hibernation.noteDiscard = { [box] event in box.planner.note(event, at: .now) }
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        _ = try rig.hiddenChat("tab_quiet", session: "s-quiet")
        _ = try rig.hiddenChat("tab_busy", session: "s-busy")
        rig.turns.setState(.working, session: "s-busy")
        rig.advance(minutes: 31)
        await rig.settle { rig.tabs.existingView("tab_quiet") == nil }

        let busy = try #require(box.planner.row("tab_busy", now: .now))
        #expect(busy.kind == .agentPage)
        #expect(busy.eligibility == .protected(.agentBusy))
        #expect((busy.hiddenFor ?? 0) >= 31 * 60)
        let quiet = try #require(box.planner.row("tab_quiet", now: .now))
        #expect(quiet.state == .discarded)
        #expect(quiet.lastDiscardReason == .proactive)

        _ = try #require(rig.tabs.view(for: "tab_quiet"))
        rig.rendering.insert("tab_quiet")
        rig.hibernation.sync { rig.rendering.contains($0) }
        let woken = try #require(box.planner.row("tab_quiet", now: .now))
        #expect(woken.state == .live)
        #expect(woken.wakeCount == 1)
        #expect(woken.visible)
    }

    @MainActor final class PlannerBox {
        var planner = ContentDiscardPlanner(tracking: .agentPage)
    }

    private static func array(_ value: JSONValue) -> [JSONValue]? {
        if case .array(let items) = value { return items }
        return nil
    }
}
