import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSettings
import AppKit
import Foundation
import Testing

/// cx-x15rz: each agent chat tab's page is a web view with its own web content process (about
/// 75 MB). A chat hidden past the browser hibernation threshold lets its page go and keeps its
/// tab: showing the tab again builds a new page on the same session, which acpmux replays. A
/// chat whose turn runs (acpmux's turn state), a New Tab page, and every chat with hibernation
/// off keep their page.
@MainActor @Suite(.serialized)
struct AgentPageHibernationTests {
    static let thisMac = "install:agent-page-hibernation-test"

    /// The store as the App holds it: tab records in a tree, pages on a page that never loads
    /// (a loopback port nobody serves) and the mock acpmux host.
    final class Rig {
        let tabs: AgentTabStore
        let hibernation: AgentPageHibernation
        var records: [String: AgentSessionRef] = [:]
        let turns = AgentTurnStateStore()
        var displaced: [String] = []
        /// The tabs the panes draw (`TabContentCache.isRendering`).
        var rendering: Set<String> = []
        /// The window a page draws in while its pane shows it.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        var elapsed: Duration = .zero
        let start = ContinuousClock.now

        init() {
            tabs = AgentTabStore(build: nil, registry: ActionRegistry(),
                                 environment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9/"], showcase: true)
            tabs.localHost = AgentPageHibernationTests.thisMac
            turns.localHost = AgentPageHibernationTests.thisMac
            turns.watching = true
            let tree = DaemonStore()
            hibernation = AgentPageHibernation(tabs: { [tabs] in tabs })
            tabs.lookup = { [unowned self] key in self.records[key].map { ($0, tree) } }
            hibernation.turnState = { [unowned self] key in self.records[key].flatMap(self.turns.state(for:)) }
            hibernation.turnsWatched = { [unowned self] in self.turns.watching }
            hibernation.followTurns(turns)
            hibernation.displace = { [unowned self] key in self.displaced.append(key) }
            hibernation.now = { [unowned self] in self.start + self.elapsed }
        }

        /// A chat of this Mac on `session`, shown in a pane, then hidden as a pane switches away:
        /// the presentation change comes while the page is still in the window, and the pane
        /// takes it out after.
        func hiddenChat(_ key: String, session: String) throws -> AgentPaneView {
            records[key] = AgentSessionRef(host: AgentPageHibernationTests.thisMac, hostName: "This Mac", session: session, harness: "claude")
            let view = try #require(tabs.view(for: key), "no page for \(key)")
            window.contentView?.addSubview(view)
            rendering.insert(key)
            hibernation.sync { self.rendering.contains($0) }
            rendering.remove(key)
            hibernation.sync { self.rendering.contains($0) }
            view.removeFromSuperview()
            return view
        }

        func advance(minutes: Double) {
            elapsed += .seconds(minutes * 60)
            hibernation.replan()
        }

        /// Waits for a release in flight (it first asks the page for its frame, for up to 2 s).
        func settle(until done: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(5)
            while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }
    }

    @MainActor final class Asked { var count = 0 }

    @Test func aChatHiddenPastTheThresholdLetsItsPageGoAndShowsTheSameChatAgain() async throws {
        let rig = Rig()
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        let page = try rig.hiddenChat("tab_quiet", session: "s-quiet")
        let busy = try rig.hiddenChat("tab_busy", session: "s-busy")
        rig.turns.setState(.working, session: "s-busy")

        // Moderate: half an hour hidden. At 20 minutes both pages stay.
        rig.advance(minutes: 20)
        await rig.settle { false }
        #expect(rig.tabs.existingView("tab_quiet") === page)

        rig.advance(minutes: 11)
        await rig.settle { rig.tabs.existingView("tab_quiet") == nil }
        #expect(rig.tabs.existingView("tab_quiet") == nil, "the hidden chat kept its page")
        #expect(rig.displaced == ["tab_quiet"], "the pane still holding the page was not told")
        #expect(rig.tabs.existingView("tab_busy") === busy, "a chat whose agent works keeps its page")
        #expect(rig.hibernation.keepsPage("tab_busy") == .agentBusy)

        // Shown again: a new page on the same chat.
        #expect(rig.tabs.session(of: "tab_quiet") == "s-quiet")
        let rebuilt = try #require(rig.tabs.view(for: "tab_quiet"))
        #expect(rebuilt !== page)
        #expect(rebuilt.model.sessionId == "s-quiet")
    }

    @Test func memoryPressureReleasesAtOnceButOffKeepsEveryPage() async throws {
        let rig = Rig()
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .off), pressure: .critical)
        let kept = try rig.hiddenChat("tab_off", session: "s-off")
        rig.advance(minutes: 120)
        await rig.settle { false }
        #expect(rig.tabs.existingView("tab_off") === kept, "hibernation off released a page")
        #expect(rig.hibernation.keepsPage("tab_off") == .disabled)

        // Critical pressure: due right away, past the short wait for the composer's last keystrokes.
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .critical)
        let page = try rig.hiddenChat("tab_pressed", session: "s-pressed")
        #expect(rig.tabs.existingView("tab_pressed") === page, "released before the composer's last keystrokes reached acpmux")
        rig.advance(minutes: 0.5)
        await rig.settle { rig.tabs.existingView("tab_pressed") == nil }
        #expect(rig.tabs.existingView("tab_pressed") == nil, "critical pressure kept a hidden chat's page")
    }

    /// A single hidden chat: no later hide, turn or setting change replans for it, so its page
    /// goes only if its own hide armed the deadline (the hide comes while it is still in the window).
    @Test func aLoneHiddenChatGoesOnItsOwnDeadline() async throws {
        let rig = Rig()
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .critical)
        _ = try rig.hiddenChat("tab_alone", session: "s-alone")
        #expect(rig.hibernation.hasDeadline, "the hide armed no deadline")
        // Critical pressure: due after the composer's short wait, with no call to replan.
        rig.elapsed += .seconds(AgentPageHibernation.minimumHidden)
        let deadline = ContinuousClock.now + .seconds(AgentPageHibernation.minimumHidden + 5)
        while rig.tabs.existingView("tab_alone") != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(rig.tabs.existingView("tab_alone") == nil, "a lone hidden chat kept its page")
    }

    /// A woken chat comes back as it was left: what its page held that acpmux does not (the
    /// composer's attachments, shell mode's unrun command, where the transcript rested) reaches
    /// the page built when it shows again, once.
    @Test func aWokenChatComesBackAsItWasLeft() async throws {
        let rig = Rig()
        let left = AgentPaneWakeState(
            attachments: [AgentPaneWakeState.Attachment(id: "a1", kind: "image", name: "shot.png", mimeType: "image/png", size: 4, data: "iVBO")],
            shell: true, shellText: "git status", scrollAnchor: AgentPaneScrollAnchor(rowId: "row-12", offset: 40))
        let asked = Asked()
        rig.hibernation.wakeState = { _ in
            asked.count += 1
            return left
        }
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        let page = try rig.hiddenChat("tab_left", session: "s-left")
        rig.advance(minutes: 61)
        await rig.settle { rig.tabs.existingView("tab_left") == nil }
        #expect(rig.tabs.existingView("tab_left") == nil, "the hidden chat kept its page")
        #expect(asked.count == 1, "the page was not asked what it held before it let go")

        let rebuilt = try #require(rig.tabs.view(for: "tab_left"))
        #expect(rebuilt !== page)
        let reply = await rebuilt.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
        let handshake = try #require(reply["value"] as? [String: Any], "\(reply)")
        let wake = try #require(handshake["wake"] as? [String: Any], "the woken page's handshake lost what it held: \(handshake)")
        let attachments = try #require(wake["attachments"] as? [[String: Any]])
        #expect(attachments.map { $0["name"] as? String } == ["shot.png"])
        #expect(attachments.first?["data"] as? String == "iVBO")
        #expect(wake["shell"] as? Bool == true)
        #expect(wake["shellText"] as? String == "git status")
        let anchor = try #require(wake["scrollAnchor"] as? [String: Any])
        #expect(anchor["rowId"] as? String == "row-12")
        #expect(anchor["offset"] as? Double == 40)

        // Handed out once: a reload of the woken page starts from acpmux alone.
        let again = await rebuilt.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
        #expect((again["value"] as? [String: Any])?["wake"] == nil)
    }

    /// Hidden things cost almost nothing (plans/cmux-next/perf-lead.md row 15): a hidden chat page
    /// is a whole web content process (about 75 MB) and stayed for the full 30 minute timeout, so
    /// a pane's five hidden chats held 375 MB. Past the page warm budget
    /// (`WarmSetBudget.pageCapacity`, as for browser pages) the chats the person left longest ago
    /// let their pages go once hidden `HibernationPlanner.overBudgetMinimumHidden`; the most
    /// recently left stay. A parked workspace's shown chat (what a switch shows again) counts
    /// `HibernationPlanner.frontCreditShare` of the timeout less idle: hidden before the others,
    /// it still stays, where a ranking by recency alone lets it go first.
    @Test func hiddenChatsPastTheWarmBudgetLetGoAfterAMinute() async throws {
        let rig = Rig()
        rig.hibernation.warmPages = { 2 }
        rig.hibernation.fronts = { ["tab_front": .parked] }
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        let front = try rig.hiddenChat("tab_front", session: "s-front")
        rig.elapsed += .seconds(1)
        let old = try rig.hiddenChat("tab_old", session: "s-old")
        rig.elapsed += .seconds(1)
        let recent = try rig.hiddenChat("tab_recent", session: "s-recent")
        #expect(rig.hibernation.hasDeadline, "no deadline for the chat past the budget")

        // Half a minute: the person may come straight back, every page stays.
        rig.advance(minutes: 0.5)
        await rig.settle { false }
        #expect(rig.tabs.existingView("tab_old") === old, "a chat left half a minute ago let its page go")

        // A minute and a half, well short of the 30 minute timeout: the chat past the budget goes.
        rig.advance(minutes: 1)
        await rig.settle { rig.tabs.existingView("tab_old") == nil }
        #expect(rig.tabs.existingView("tab_old") == nil, "a hidden chat past the warm budget kept its page until the timeout")
        #expect(rig.displaced == ["tab_old"])
        #expect(rig.tabs.existingView("tab_recent") === recent, "the most recently left chat (inside the budget) let its page go")
        #expect(rig.tabs.existingView("tab_front") === front, "a parked workspace's shown chat went before a chat nobody shows")
        #expect(rig.tabs.session(of: "tab_old") == "s-old", "the released chat lost its session")
    }

    /// Parked workspaces' shown chats count in the budget too: a STRESS session's parked
    /// workspaces each kept a 75 MB chat page for the whole 30 minute timeout, O(workspaces). Past
    /// the budget the workspaces left longest ago let their chat page go after a minute. The
    /// workspace left last (`.warm`) keeps its chat out of the budget, so a switch back is live.
    @Test func parkedWorkspacesShownChatsCountInTheBudget() async throws {
        let rig = Rig()
        rig.hibernation.warmPages = { 1 }
        rig.hibernation.fronts = { ["tab_ws_old": .parked, "tab_ws_recent": .parked, "tab_ws_last": .warm] }
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        let old = try rig.hiddenChat("tab_ws_old", session: "s-ws-old")
        rig.elapsed += .seconds(1)
        let recent = try rig.hiddenChat("tab_ws_recent", session: "s-ws-recent")
        rig.elapsed += .seconds(1)
        let last = try rig.hiddenChat("tab_ws_last", session: "s-ws-last")
        #expect(rig.hibernation.hasDeadline, "no deadline for the parked chat past the budget")

        rig.advance(minutes: 1.5)
        await rig.settle { rig.tabs.existingView("tab_ws_old") == nil }
        #expect(rig.tabs.existingView("tab_ws_old") !== old, "a parked workspace's chat past the budget kept its page until the timeout")
        #expect(rig.tabs.existingView("tab_ws_recent") === recent, "the most recently left workspace's chat let its page go")
        #expect(rig.tabs.existingView("tab_ws_last") === last, "the chat of the workspace left last let its page go")
        #expect(rig.displaced == ["tab_ws_old"])
    }

    /// A pane switch hides its old chat before the pane reports its new shown tab, so the hide is
    /// planned while the chat is still a warm front (out of the budget, the 30 minute timeout).
    /// When the fronts move (`BrowserHibernation.refreshNeighbors`), the chat planner plans again:
    /// past the budget the hidden chat goes after a minute, not after the timeout.
    @Test func aChatHiddenByASwitchInItsPaneCountsOnceTheFrontsMove() async throws {
        let rig = Rig()
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let browser = BrowserHibernation(cache: services.cache)
        services.cache.hibernation = browser
        defer { browser.stop() }
        let pane = NSObject()
        browser.paneDidChange(ObjectIdentifier(pane), order: ["tab_was_shown", "tab_next"], selected: "tab_was_shown")
        rig.hibernation.fronts = { [weak browser] in browser?.fronts ?? [:] }
        rig.hibernation.warmPages = { 0 }
        browser.agentPages = rig.hibernation
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)

        _ = try rig.hiddenChat("tab_was_shown", session: "s-was-shown")
        let stale = try #require(rig.hibernation.nextCheck)
        #expect(stale > 25 * 60, "the hide was not planned with the fronts before the switch (the test's premise)")

        browser.paneDidChange(ObjectIdentifier(pane), order: ["tab_was_shown", "tab_next"], selected: "tab_next")
        let next = try #require(rig.hibernation.nextCheck, "no deadline for the hidden chat past the budget")
        #expect(next <= HibernationPlanner.overBudgetMinimumHidden, "the chat kept its page for the timeout after the fronts moved")
        withExtendedLifetime(pane) {}
    }

    /// With the acpmux turn watch down no chat's turn is known: every chat counts as busy and
    /// keeps its page until the watch is back.
    @Test func withTheTurnWatchDownEveryChatKeepsItsPage() async throws {
        let rig = Rig()
        rig.turns.watching = false
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        let page = try rig.hiddenChat("tab_unknown", session: "s-unknown")
        rig.advance(minutes: 61)
        await rig.settle { false }
        #expect(rig.tabs.existingView("tab_unknown") === page, "a chat whose turn nobody knows let its page go")
        #expect(rig.hibernation.keepsPage("tab_unknown") == .agentTurnsUnknown)

        // The watch is back and the chat idle: its overdue page goes without another hide.
        rig.turns.watching = true
        await rig.settle { rig.tabs.existingView("tab_unknown") == nil }
        #expect(rig.tabs.existingView("tab_unknown") == nil, "the watch came back and the idle chat kept its page")
    }
}
