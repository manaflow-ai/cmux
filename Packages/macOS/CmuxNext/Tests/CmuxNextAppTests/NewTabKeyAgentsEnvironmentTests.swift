import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextHibernation
import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// The plan of the hidden agent pages (`HiddenChatPages`) asks one question for each hidden page of a pane: is this
/// page the chat face of a terminal that its pane draws now (`pairedFace`, Toggle Terminal and Chat). The plan runs
/// when a tab stops drawing, when a page is built and on its timers, so it runs for each New Tab key, and each New
/// Tab key leaves one more hidden page in its pane. What the question costs is so paid for each hidden page at each
/// key.
///
/// The app's agents environment (`QuitAgents.environment`) searches paths and checks a signature on the calling
/// thread. The question needs the chat's session only, so it must ask no environment: not in a key's own turn and
/// not in a pass of the plan over the pane's hidden pages.
///
/// What this holds and what it does not: the package's rig starts no hibernation (the app delegate does that), so
/// the test makes the App's own plan for the rig's services, with the App's own question. The asks are counted over
/// calls that have no suspension (a key's own call, one pass of the plan), so no other suite can add to the count.
/// The controls say that the pass asked the question for the hidden pages and that the app finds each one's tab.
/// A pass at a frame or on a timer is the same call; no test here waits for the app's own timer.
///
/// One hidden page has a run in the store at the pass. Toggle Terminal and Chat's facts ask the environment only for
/// a chat with a run of this Mac, so only such a page makes a question that reads those facts ask it. The keys' own
/// turns are counted before that page has its run.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabKeyAgentsEnvironmentTests {
    /// The asks of the agents environment that `body` makes, by the app's own instrument: `BenchSpans` has one span
    /// `agents.environment` for each ask while a bench records. `body` has no suspension, so the count is of `body`
    /// alone. A bench of another suite that records now (the suites share the main actor) keeps its record while its
    /// ring of spans has room: this starts no second one, and adds 2 marks `test.probe` to that record. With a full
    /// ring the probe adds no mark, so this can not see that bench: it starts its own record and ends that one.
    /// nil when the ring of spans filled meanwhile, so the count is not whole.
    private static func environmentAsks(in body: () -> Void) -> Int? {
        let had = BenchSpans.spans.count
        BenchSpans.mark("test.probe")
        let another = BenchSpans.spans.count > had
        if !another { BenchSpans.begin() }
        defer { if !another { _ = BenchSpans.end() } }
        let before = BenchSpans.spans.filter { $0.name == "agents.environment" }.count
        body()
        let after = BenchSpans.spans
        BenchSpans.mark("test.probe")
        guard BenchSpans.spans.count > after.count else { return nil }
        return after.filter { $0.name == "agents.environment" }.count - before
    }

    /// One New Tab key, so the pane has a page; then `keys` New Tab keys, each with a hidden page in the pane before
    /// it, and a frame after each; then one pass of the plan over the hidden pages. The count of the asks is 0 for a
    /// few keys and for more keys alike.
    ///
    /// The row needs a hidden page for each key. The tab of a New Tab key takes the page view of the untouched New
    /// Tab tab that its pane leaves (`AgentTabStore.idlePage`), and then the pane has one page view for all its keys.
    /// So the row counts each New Tab page as used before each key (`NewTabOpenFramesTests.useEachNewTabPage`), as
    /// after a click in the page: each key's tab then gets a page view of its own at its frame.
    @Test(arguments: [3, 8])
    func newTabKeysAndThePlanOverTheirHiddenPagesAskNoAgentsEnvironment(keys: Int) async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-keys-ask-no-environment-\(keys)") { services, _, pane, _ in
            let plan = AgentPageHibernation(services: services)
            defer { plan.pages.stop() }
            // Each question of the plan, by its page; the App's own closure answers it.
            let question = plan.pages.pairedFace
            var asked: [String] = []
            plan.pages.pairedFace = { key in
                asked.append(key)
                return question(key)
            }
            // The pages whose tab the question finds: a tab of the app that is no terminal.
            let chatPages: () -> [String] = {
                (plan.hibernationPages() ?? [:]).keys.filter { key in
                    services.locateTab(AgentTabKey(relaunchStorageKey: key).key).map { $0.0.kind != .pty } ?? false
                }
            }

            NewTabPage.open(in: pane, seed: nil)
            await NewTabPageAtItsFrameTests.frame(services)
            var asksInTheKeysTurns = 0
            for _ in 0..<keys {
                NewTabOpenFramesTests.useEachNewTabPage(services)
                let asks = Self.environmentAsks { NewTabPage.open(in: pane, seed: nil) }
                let made = try #require(asks, "the count of a key's asks is not whole")
                asksInTheKeysTurns += made
                await NewTabPageAtItsFrameTests.frame(services)
            }
            // The store has each page's tab: from then on the question finds it.
            try await PasswordManagerRouteTests.until({ chatPages().count > keys },
                                                      report: { "\(chatPages().count) of \(keys + 1) pages have a tab that the app finds" })

            // One hidden page gets a run in the store, as a chat that runs on this Mac has one.
            let tabs = services.agentTabs
            let hiddenTab = chatPages().lazy.compactMap { services.locateTab(AgentTabKey(relaunchStorageKey: $0).key)?.0 }
                .first { !services.cache.isRendering($0.id) }
            let withARun = try #require(hiddenTab, "no hidden page has a tab")
            tabs.sessions[tabs.tabKey(of: withARun)] = "run-of-the-test-\(keys)"
            let hasARunHere = tabs.session(of: withARun.id) != nil && tabs.remoteMachineID(of: withARun.id) == nil
            try #require(hasARunHere, "the store does not say that the hidden page \(withARun.id) has a run of this Mac")

            // One pass of the plan and of its compare, with no suspension.
            asked = []
            let plans = plan.pages.replans
            let pass = Self.environmentAsks {
                plan.replan()
                plan.sync(nil) { services.cache.isRendering($0) }
            }
            let asksInThePass = try #require(pass, "the count of the pass's asks is not whole")
            let found = Set(chatPages()), hidden = Set(asked).intersection(found)
            print("asks-of-test: NewTabKeyAgentsEnvironmentTests \(keys) keys: \(asksInTheKeysTurns) asks in the keys' turns, "
                + "\(asksInThePass) asks in the pass, \(asked.count) questions for \(hidden.count) hidden pages")

            try #require(plan.pages.replans > plans, "the plan did not run")
            try #require(hidden.count >= keys,
                         "the plan asked its question for \(hidden.count) hidden pages with a tab, of \(keys) at least: \(asked)")
            let askedForTheRun = asked.contains { AgentTabKey(relaunchStorageKey: $0).key == withARun.id }
            try #require(askedForTheRun, "the plan did not ask its question for the hidden page with a run \(withARun.id): \(asked)")
            #expect(asksInThePass == 0,
                    "one pass of the plan asked the agents environment \(asksInThePass) times for \(asked.count) questions of \(hidden.count) hidden pages")
            #expect(asksInTheKeysTurns == 0, "\(keys) New Tab keys asked the agents environment \(asksInTheKeysTurns) times in their own turns")
        }
    }

    /// The second form of the keys' own turns (`NewTabHoldMovesItsPageTests+IdleStart.swift`): no page counts as
    /// used, so each key's tab takes the page view of the untouched New Tab tab that its pane leaves. That each key
    /// took that view is a condition of the setup. Want: 0 asks of the agents environment in the keys' own turns.
    ///
    /// The pass of the plan has the first form only: with one page view for all its keys the pane has no hidden page.
    @Test(arguments: [3])
    func newTabKeysThatTakeAnIdlePageViewAskNoAgentsEnvironment(keys: Int) async throws {
        try await NewTabHoldMovesItsPageTests.row("cn-keys-idle-ask-no-environment") { services, pane, _, _ in
            let tabs = services.agentTabs
            var asksInTheKeysTurns = 0, took = 0
            for _ in 0..<keys {
                let left = pane.currentTabKey, idle = left.flatMap { tabs.existingView($0) }
                let asks = Self.environmentAsks { NewTabPage.open(in: pane, seed: nil) }
                asksInTheKeysTurns += try #require(asks, "the count of a key's asks is not whole")
                if let idle, pane.currentTabKey != left, pane.currentTabKey.flatMap({ tabs.existingView($0) }) === idle { took += 1 }
                await NewTabPageAtItsFrameTests.frame(services)
            }
            print("asks-of-test: NewTabKeyAgentsEnvironmentTests the second form, \(keys) keys: \(took) keys took the page view of the tab "
                + "that the pane left, \(asksInTheKeysTurns) asks in the keys' turns")
            try #require(took == keys, "setup: \(took) of \(keys) New Tab keys took the page view of the tab that the pane left")
            #expect(asksInTheKeysTurns == 0, "\(keys) New Tab keys that took an idle page view asked the agents environment \(asksInTheKeysTurns) times in their own turns")
        }
    }
}
