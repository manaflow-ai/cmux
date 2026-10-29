import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHibernation
import CmuxNextInput
import CmuxNextPages
import CmuxNextSettings
import AppKit
import CmuxNextWakeups
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
            tabs = AgentTabStore(build: nil, registry: ActionRegistry(), work: BackgroundWork(label: "test.agent-pane"), webUI: .agentTabsTestHost(), input: InputEventTap(),
                                 environment: AgentPageAppTestRoot.environment, showcase: true)
            tabs.localHost = AgentPageHibernationTests.thisMac
            turns.localHost = AgentPageHibernationTests.thisMac
            turns.watching = true
            let tree = DaemonStore()
            hibernation = AgentPageHibernation(tabs: { [tabs] in tabs }, deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())))
            tabs.lookup = { [unowned self] key in self.records[key].map { ($0, tree) } }
            hibernation.turnState = { [unowned self] key in self.records[key].flatMap(self.turns.state(for:)) }
            hibernation.turnsWatched = { [unowned self] in self.turns.watching }
            hibernation.followTurns(turns)
            hibernation.displace = { [unowned self] key in self.displaced.append(key) }
            hibernation.now = { [unowned self] in self.start + self.elapsed }
        }

        /// A chat of this Mac on `session`, shown in a pane, then hidden as a pane switches away:
        /// the presentation change comes while the page is still in the window, and the pane
        /// takes it out after (`leavesWindow: false`: the pane has not taken it out yet).
        func hiddenChat(_ key: String, session: String, leavesWindow: Bool = true) throws -> AgentPaneView {
            records[key] = AgentSessionRef(host: AgentPageHibernationTests.thisMac, hostName: "This Mac", session: session, harness: "claude")
            let view = try #require(tabs.view(for: key), "no page for \(key)")
            window.contentView?.addSubview(view)
            rendering.insert(key)
            hibernation.sync { self.rendering.contains($0) }
            rendering.remove(key)
            hibernation.sync { self.rendering.contains($0) }
            if leavesWindow { view.removeFromSuperview() }
            return view
        }

        func advance(minutes: Double) {
            elapsed += .seconds(minutes * 60)
            hibernation.replan()
        }

        /// Waits for a release in flight (it first asks the page for its frame, for up to 2 s).
        func settle(for seconds: Double = 5, until done: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }
    }

    @MainActor final class Asked { var count = 0 }

    @Test func aChatHiddenPastTheThresholdLetsItsPageGoAndShowsTheSameChatAgain() async throws {
        let rig = Rig()
        let released = Asked()
        rig.hibernation.onRelease = { released.count += 1 }
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
        #expect(released.count == 1, "the memory histograms' release hook did not fire once for the one released page")

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

    /// No `browser.hibernation` in cmux.json: a hidden chat keeps its page at every pressure, as a
    /// browser tab does. A page built again loses what ``AgentPaneWakeState`` does not carry (an open
    /// menu or popover, the caret, a queued prompt being edited, an IME composition).
    @Test(arguments: [MemoryPressureLevel.normal, .critical])
    func theDefaultKeepsEveryHiddenChatsPage(_ pressure: MemoryPressureLevel) async throws {
        let rig = Rig()
        rig.hibernation.update(setting: .fallback, pressure: pressure)
        let page = try rig.hiddenChat("tab_default", session: "s-default")
        rig.advance(minutes: 120)
        await rig.settle { rig.tabs.existingView("tab_default") == nil }
        #expect(rig.tabs.existingView("tab_default") === page, "a hidden chat was recreated by default")
        #expect(rig.hibernation.keepsPage("tab_default") == .keepsState)
        #expect(!rig.hibernation.hasDeadline)
        #expect(rig.displaced.isEmpty)
    }

    /// A chat whose page crashed shows the notice at once and does not reload by itself: the page
    /// host keeps no automatic reload for it and reports the crash as not reloading (the page host's
    /// own test is `PageWebViewCrashReloadTests`).
    @Test func aCrashedChatShowsTheNoticeAndDoesNotReload() throws {
        let rig = Rig()
        let view = try rig.hiddenChat("tab_crash", session: "s-crash")
        #expect(!view.page.reloadsAfterCrash, "the agent page host reloads a crashed chat")
        view.pageCrashed(reloading: false)
        #expect(view.crashNotice != nil, "a crashed chat showed no notice")
    }

    /// Even with a timeout written, a crashed chat keeps its page and notice: a release would
    /// build it again when shown, a reload the person did not ask for.
    @Test func aCrashedChatIsNeverReleased() async throws {
        let rig = Rig()
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .critical)
        let view = try rig.hiddenChat("tab_crashed", session: "s-crashed")
        view.pageCrashed(reloading: false)
        rig.advance(minutes: 61)
        await rig.settle { rig.tabs.existingView("tab_crashed") == nil }
        #expect(rig.tabs.existingView("tab_crashed") === view, "a crashed chat was released and rebuilt")
        #expect(rig.hibernation.keepsPage("tab_crashed") == .unsupported)
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

    /// Hides chats `keys` one second apart, oldest first; the ones in `inWindow` stay in their window.
    private func hideInOrder(_ keys: [String], inWindow: Set<String> = [], on rig: Rig) throws -> [String: AgentPaneView] {
        var pages: [String: AgentPaneView] = [:]
        for key in keys {
            pages[key] = try rig.hiddenChat(key, session: "s-\(key)", leavesWindow: !inWindow.contains(key))
            rig.elapsed += .seconds(1)
        }
        return pages
    }

    /// Past the Mac's budget of live hidden agent pages, the least recently shown
    /// ones go at once, long before the timeout, but never one hidden less than `minimumHidden`.
    /// Without a budget only the timeout lets pages go.
    @Test func pastTheBudgetTheLeastRecentlyShownPagesGoAtOnce() async throws {
        let rig = Rig()
        let released = Asked()
        rig.hibernation.onRelease = { released.count += 1 }
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        let keys = ["tab_a", "tab_b", "tab_c", "tab_d", "tab_e", "tab_f"]
        let pages = try hideInOrder(keys, on: rig)

        // No budget (the feature off): 15 s hidden, far inside the half hour, every page stays.
        rig.elapsed += .seconds(AgentPageHibernation.minimumHidden)
        rig.hibernation.replan()
        await rig.settle { false }
        for key in keys { #expect(rig.tabs.existingView(key) === pages[key], "\(key) went with no budget") }

        // Budget 4 of 6: the two oldest go, without waiting for the timeout.
        rig.hibernation.liveHiddenLimit = 4
        await rig.settle { rig.tabs.existingView("tab_a") == nil && rig.tabs.existingView("tab_b") == nil }
        #expect(rig.tabs.existingView("tab_a") == nil, "the least recently shown page stayed past the budget")
        #expect(rig.tabs.existingView("tab_b") == nil, "the second least recently shown page stayed past the budget")
        for key in keys.dropFirst(2) { #expect(rig.tabs.existingView(key) === pages[key], "\(key) went within the budget") }
        #expect(Set(rig.displaced) == ["tab_a", "tab_b"])
        #expect(released.count == 2)
        #expect(rig.tabs.session(of: "tab_a") == "s-tab_a", "a released chat lost its session")

        // Within the budget now: another plan lets nothing more go.
        rig.hibernation.replan()
        await rig.settle { false }
        for key in keys.dropFirst(2) { #expect(rig.tabs.existingView(key) === pages[key], "\(key) went within the budget") }
        #expect(released.count == 2)
    }

    /// The budget counts every live hidden page, the busy ones too, but a chat whose agent works
    /// or waits on the person never goes: the oldest idle ones go in their place. A page hidden
    /// less than `minimumHidden` waits, on its own deadline (not the half hour's): the deadline
    /// alone lets them go. With the turn watch down nothing goes.
    @Test func pastTheBudgetBusyChatsStayAndYoungPagesWait() async throws {
        let rig = Rig()
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        rig.hibernation.liveHiddenLimit = 4
        let keys = ["tab_working", "tab_asking", "tab_c", "tab_d", "tab_e", "tab_f"]
        let pages = try hideInOrder(keys, on: rig)
        rig.turns.setState(.working, session: "s-tab_working")
        rig.turns.setState(.needsInput, session: "s-tab_asking")

        // Hidden 1 to 6 s: over the budget, but every page is too young to go.
        await rig.settle { false }
        for key in keys { #expect(rig.tabs.existingView(key) === pages[key], "\(key) went before the composer's short wait") }
        // The oldest idle page (tab_c, hidden 4 s) is due in 6 s, not at the half hour's timeout.
        let delay = try #require(rig.hibernation.deadlineDelay, "over the budget with young pages armed no deadline")
        #expect(delay <= AgentPageHibernation.minimumHidden, "the young pages wait on the timeout (\(delay) s), not the budget")

        // No call to replan: the armed deadline alone lets the two oldest idle pages go.
        rig.elapsed += .seconds(AgentPageHibernation.minimumHidden)
        await rig.settle(for: AgentPageHibernation.minimumHidden + 5) {
            rig.tabs.existingView("tab_c") == nil && rig.tabs.existingView("tab_d") == nil
        }
        #expect(rig.tabs.existingView("tab_working") === pages["tab_working"], "a chat whose agent works went for the budget")
        #expect(rig.tabs.existingView("tab_asking") === pages["tab_asking"], "a chat waiting on the person went for the budget")
        #expect(rig.hibernation.keepsPage("tab_working") == .agentBusy)
        #expect(rig.hibernation.keepsPage("tab_asking") == .agentBusy)
        #expect(rig.tabs.existingView("tab_c") == nil, "the oldest idle chat stayed past the budget")
        #expect(rig.tabs.existingView("tab_d") == nil, "the second oldest idle chat stayed past the budget")
        #expect(rig.tabs.existingView("tab_e") === pages["tab_e"])
        #expect(rig.tabs.existingView("tab_f") === pages["tab_f"])
        #expect(Set(rig.displaced) == ["tab_c", "tab_d"])

        // With the turn watch down no turn is known: nothing more goes, even past the budget.
        rig.turns.watching = false
        _ = try hideInOrder(["tab_g", "tab_h"], on: rig)
        rig.elapsed += .seconds(AgentPageHibernation.minimumHidden)
        rig.hibernation.replan()
        await rig.settle { false }
        for key in ["tab_e", "tab_f", "tab_g", "tab_h"] {
            #expect(rig.tabs.existingView(key) != nil, "\(key) went with no turn known")
        }
    }

    /// Over the budget, the oldest page still in its window (the pane has not taken it out yet)
    /// counts as going: no younger page goes in its place, and a short recheck lets it go once
    /// the pane takes it out, with no other event.
    @Test func pastTheBudgetAPageStillInItsWindowGoesOnItsRecheck() async throws {
        let rig = Rig()
        let released = Asked()
        rig.hibernation.onRelease = { released.count += 1 }
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        let keys = ["tab_a", "tab_b", "tab_c", "tab_d"]
        let pages = try hideInOrder(keys, inWindow: ["tab_a"], on: rig)
        // Hidden 9 to 12 s: tab_a and tab_b are past the composer's short wait.
        rig.elapsed += .seconds(AgentPageHibernation.minimumHidden - 2)

        // Budget 2 of 4: tab_a counts as going, so only tab_b goes now.
        rig.hibernation.liveHiddenLimit = 2
        await rig.settle { false }
        #expect(rig.tabs.existingView("tab_a") === pages["tab_a"], "a page still in its window went")
        #expect(rig.tabs.existingView("tab_b") == nil, "the oldest page out of its window stayed past the budget")
        #expect(rig.tabs.existingView("tab_c") === pages["tab_c"], "a younger page went in place of the one still in its window")
        #expect(rig.tabs.existingView("tab_d") === pages["tab_d"])
        #expect(released.count == 1)
        let delay = try #require(rig.hibernation.deadlineDelay, "the page in its window armed no recheck")
        #expect(delay <= AgentPageHibernation.minimumHidden, "the page in its window waits on the timeout (\(delay) s), not a recheck")

        // The pane takes it out; no call to replan: the recheck lets it go.
        pages["tab_a"]?.removeFromSuperview()
        await rig.settle(for: AgentPageHibernation.minimumHidden + 5) { rig.tabs.existingView("tab_a") == nil }
        #expect(rig.tabs.existingView("tab_a") == nil, "the recheck did not let the page out of its window go")
        #expect(rig.tabs.existingView("tab_c") === pages["tab_c"], "a page within the budget went")
        #expect(rig.tabs.existingView("tab_d") === pages["tab_d"], "a page within the budget went")
        #expect(released.count == 2)
    }

    /// p13-webui-092 (`memoryUrgentDiscardRanking`): critical pressure releases no chat in its own turn,
    /// as it did before (every hidden chat past the minimum at once): the app's urgent pass ranks the
    /// chats with the tabs and pages and takes one. Then the timeout lets one go per urgent pace interval.
    @Test func withTheUrgentRankingTheCriticalEventsChatDiscardIsTheUrgentPasss() async throws {
        let rig = Rig()
        rig.hibernation.leavesCriticalEventToUrgentPass = true
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        let keys = ["tab_a", "tab_b", "tab_c"]
        let pages = try hideInOrder(keys, on: rig)
        rig.elapsed += .seconds(60)
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .critical)
        await rig.settle { false }
        for key in keys { #expect(rig.tabs.existingView(key) === pages[key], "\(key) went in the critical event's own turn") }
        let candidates = rig.hibernation.urgentCandidates()
        #expect(Set(candidates.map(\.key)) == Set(keys))
        #expect(candidates.allSatisfy { $0.kind == .agentPage })

        #expect(rig.hibernation.urgentDiscard("tab_b"))
        rig.hibernation.urgentPassDidRun()
        await rig.settle { rig.tabs.existingView("tab_b") == nil }
        #expect(rig.tabs.existingView("tab_b") == nil, "the chat the urgent pass chose kept its page")
        #expect(rig.tabs.existingView("tab_a") === pages["tab_a"], "a second chat went with the urgent pass")
        #expect(rig.tabs.existingView("tab_c") === pages["tab_c"], "a second chat went with the urgent pass")

        rig.elapsed += .seconds(HibernationPlanner.Pace.chromeUrgent.interval)
        rig.hibernation.replan()
        await rig.settle { rig.tabs.existingView("tab_a") == nil }
        #expect(rig.tabs.existingView("tab_a") == nil, "the oldest chat did not go at the urgent pace")
        #expect(rig.tabs.existingView("tab_c") === pages["tab_c"], "two chats went in one urgent pace interval")
    }
}
