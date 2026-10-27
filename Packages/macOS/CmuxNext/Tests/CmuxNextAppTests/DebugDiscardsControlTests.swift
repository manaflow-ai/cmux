import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextBridge
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextSettings
import Foundation
import Testing

/// `debug.discards` (p07-memory task 011): cmux's chrome://discards, served by release builds too.
/// The app's owners report their contents where they decide: BrowserHibernation each browser page
/// (hide, each pass's verdict, every keep after the probe, the discard and its reason, the wake, the
/// close) and AgentPageHibernation each agent page. ContentDiscardReportTests covers the rows and
/// the nine kinds; this suite drives the real owners and the registered method.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct DebugDiscardsControlTests {
    // MARK: The method

    /// A release router keeps `debug.discards` (read-only, tab keys only) and drops the pressure
    /// override; a DEBUG router serves both. `{"kind": "browser"}` keeps the browser rows.
    @Test func releaseBuildsServeTheReportAndTheKindParameterFilters() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(), deadlines: services.mainDeadlines)
        services.cache.hibernation = hibernation
        hibernation.noteDiscard(.hidden("tab-page", .browser))
        hibernation.noteDiscard(.hidden("tab-chat", .agentPage))
        for allowsDebug in [false, true] {
            let router = Self.router(services, allowsDebug: allowsDebug)
            #expect(router.method(named: "debug.discards")?.servesRelease == true)
            #expect((router.method(named: "debug.hibernation.pressure") != nil) == (allowsDebug && ControlRouter.debugMethodsAllowed),
                    "the pressure override is a DEBUG method only")
            let reply = try await router.handle(ControlRequest(id: "1", method: "debug.discards", params: ["kind": "browser"])).get()
            let rows = try #require(reply["contents"].flatMap(Self.array))
            #expect(rows.compactMap { $0["key"]?.stringValue } == ["tab-page"])
            #expect(rows.first?["eligibility"] == "protected")
            #expect(rows.first?["reason"] == "recently_visible")
            #expect(reply["kinds"].flatMap(Self.array)?.compactMap { $0["kind"]?.stringValue } == ["browser"])
        }

        // Before hibernation starts: the nine kinds, none tracked, no rows.
        services.cache.hibernation = nil
        let empty = try await Self.router(services, allowsDebug: false).handle(ControlRequest(id: "2", method: "debug.discards", params: [:])).get()
        #expect(empty["contents"].flatMap(Self.array)?.isEmpty == true)
        let kinds = try #require(empty["kinds"].flatMap(Self.array))
        #expect(kinds.count == ContentKind.allCases.count)
        #expect(kinds.allSatisfy { $0["tracked"] == false && $0["reason"] == "not_a_tab" })
        withExtendedLifetime((services, hibernation)) {}
    }

    // MARK: Browser pages

    /// One page from hide to close, and one that goes under memory pressure: each pass's verdict
    /// is from that pass (off, then on again, flips it back to eligible), the person's Hibernate Tab
    /// is external, the critical plan's discard urgent, a show counts one wake, and a close drops the row.
    @Test func browserHibernationReportsEachPageFromHideToClose() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let asked = try await rig.hide(rig.page("asked", body: "<p>asked</p>"))
        var row = try #require(rig.hibernation.discards.row(asked, now: .now))
        #expect(row.kind == .browser && !row.visible && row.state == .live)
        #expect(row.eligibility == DiscardEligibility(), "a hidden page the critical pass ranks is eligible: \(row)")

        rig.hibernation.apply(BrowserHibernationSetting(mode: .off))
        #expect(rig.hibernation.discards.row(asked, now: .now)?.eligibility == DiscardEligibility(keptFor: .disabled))
        rig.hibernation.apply(BrowserHibernationSetting(mode: .moderate))
        #expect(rig.hibernation.discards.row(asked, now: .now)?.eligibility == DiscardEligibility(),
                "the disabled verdict outlived the pass that turned hibernation on")

        #expect(rig.hibernation.hibernateNow(asked) == nil)
        try await rig.until("the asked page hibernated") { rig.isHibernated(asked) }
        row = try #require(rig.hibernation.discards.row(asked, now: .now))
        #expect(row.state == .discarded)
        #expect(row.lastDiscardReason == .external)
        #expect(row.eligibility == DiscardEligibility(result: .disallowed, reasons: [.alreadyDiscarded]))

        let pressed = try await rig.hide(rig.page("pressed", body: "<p>pressed</p>"))
        try await rig.until("the page hibernated under pressure") { rig.isHibernated(pressed) || rig.exemption(pressed) != nil }
        #expect(rig.hibernation.discards.row(pressed, now: .now)?.lastDiscardReason == .urgent)

        rig.services.cache.present(asked, by: rig.pane, presence: .visible)
        try await rig.until("the page woke") { !rig.isHibernated(asked) && rig.services.cache.phase(of: asked) == .mountedVisible }
        row = try #require(rig.hibernation.discards.row(asked, now: .now))
        #expect(row.state == .live && row.visible && row.hiddenFor == nil)
        #expect(row.wakeCount == 1)
        #expect(row.lastDiscardReason == .external, "the last discard's reason went with the wake")
        #expect(row.eligibility == DiscardEligibility(result: .protected, reasons: [.visible]))

        rig.services.cache.release(pressed)
        #expect(rig.hibernation.discards.row(pressed, now: .now) == nil, "a closed tab kept its row")
    }

    /// A page the probe keeps (the person's typing) says so at once: the keep reports its verdict,
    /// with no later pass needed.
    @Test func aPageTheProbeKeepsIsReportedProtectedWithTheProbesReason() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await rig.page("typed", body: "<input id='note'>")
        rig.window.contentView = page.contentView
        rig.window.makeFirstResponder(page.webView)
        _ = try await page.evaluate("document.getElementById('note').focus(); true", world: .page, gesture: .agent)
        page.webView.insertText("draft")
        try await rig.until("the typing reached the page") {
            (try? await page.evaluate("document.getElementById('note').value", world: .page, gesture: .agent)) == .string("draft")
        }
        rig.window.contentView = nil
        let key = try await rig.hide(page)
        try await rig.until("the page was kept") { rig.exemption(key) != nil }
        try #require(rig.exemption(key) == .formInput)
        let row = try #require(rig.hibernation.discards.row(key, now: .now))
        #expect(row.eligibility == DiscardEligibility(keptFor: .formInput), "debug.discards and debug.surfaces disagree: \(row)")
        #expect(row.lastDiscardReason == nil, "a kept page was reported as discarded")
    }

    // MARK: Agent pages

    /// A real agent page through AgentPageHibernation: kept while its agent works, released when
    /// due (proactive), and one wake once its tab builds the page again.
    @Test func agentPageHibernationReportsVerdictsDiscardsAndWakes() async throws {
        let rig = AgentPageHibernationTests.Rig()
        let box = ReportBox()
        rig.hibernation.noteDiscard = { [box] event in box.report.note(event, at: .now) }
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        _ = try rig.hiddenChat("tab_quiet", session: "s-quiet")
        _ = try rig.hiddenChat("tab_busy", session: "s-busy")
        rig.turns.setState(.working, session: "s-busy")
        rig.advance(minutes: 31)
        await rig.settle { rig.tabs.existingView("tab_quiet") == nil }

        let busy = try #require(box.report.row("tab_busy", now: .now))
        #expect(busy.kind == .agentPage)
        #expect(busy.eligibility == DiscardEligibility(keptFor: .agentBusy))
        #expect((busy.hiddenFor ?? 0) >= 31 * 60)
        let quiet = try #require(box.report.row("tab_quiet", now: .now))
        #expect(quiet.state == .discarded)
        #expect(quiet.lastDiscardReason == .proactive)

        _ = try #require(rig.tabs.view(for: "tab_quiet"))
        rig.rendering.insert("tab_quiet")
        rig.hibernation.sync { rig.rendering.contains($0) }
        let woken = try #require(box.report.row("tab_quiet", now: .now))
        #expect(woken.state == .live)
        #expect(woken.wakeCount == 1)
        #expect(woken.visible)
    }

    /// A connected page that does not say what it holds stays, and its row says why at once.
    @Test func anAgentPageKeptForNoWakeStateIsReportedUnanswered() async throws {
        let rig = AgentPageHibernationTests.Rig()
        let box = ReportBox()
        rig.hibernation.noteDiscard = { [box] event in box.report.note(event, at: .now) }
        rig.hibernation.wakeState = { _ in nil }
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        let page = try rig.hiddenChat("tab_silent", session: "s-silent")
        _ = await page.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
        rig.advance(minutes: 61)
        await rig.settle { box.report.row("tab_silent", now: .now)?.eligibility.reason == .unanswered }
        #expect(rig.tabs.existingView("tab_silent") != nil, "a page that did not say what it held let go")
        #expect(box.report.row("tab_silent", now: .now)?.eligibility == DiscardEligibility(keptFor: .unanswered))
    }

    @MainActor final class ReportBox {
        var report = ContentDiscardReport(tracking: .agentPage)
    }

    private static func router(_ services: AppServices, allowsDebug: Bool) -> ControlRouter {
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: services.registry), settings: nil,
                                   configuration: ControlRouter.Configuration(allowsDebugMethods: allowsDebug))
        router.register(DebugHibernationControl.methods(services))
        return router
    }

    private static func array(_ value: JSONValue) -> [JSONValue]? {
        if case .array(let items) = value { return items }
        return nil
    }
}
