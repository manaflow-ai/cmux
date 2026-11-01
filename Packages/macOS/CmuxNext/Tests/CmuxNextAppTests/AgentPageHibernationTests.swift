import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import AppKit
import CmuxNextTestSupport
import Foundation
import Testing

/// cx-x15rz: each agent chat tab's page is a web view with its own web content process (about
/// 75 MB). A chat hidden past the browser hibernation threshold lets its page go and keeps its
/// tab: showing the tab again builds a new page on the same session, which acpmux replays. A
/// chat whose turn runs (acpmux's turn state), a New Tab page, and every chat with hibernation
/// off keep their page.
@MainActor @Suite(.serialized, .closesItsWindows)
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
        defer { rig.window.closeAfterTest() }
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
        defer { rig.window.closeAfterTest() }
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
        defer { rig.window.closeAfterTest() }
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
        defer { rig.window.closeAfterTest() }
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
        defer { rig.window.closeAfterTest() }
        rig.hibernation.update(setting: .fallback, pressure: pressure)
        let page = try rig.hiddenChat("tab_default", session: "s-default")
        rig.advance(minutes: 120)
        await rig.settle { rig.tabs.existingView("tab_default") == nil }
        #expect(rig.tabs.existingView("tab_default") === page, "a hidden chat was recreated by default")
        #expect(rig.hibernation.keepsPage("tab_default") == .keepsState)
        #expect(!rig.hibernation.hasDeadline)
        #expect(rig.displaced.isEmpty)
    }

    /// A hidden chat whose page crashed shows no notice: it owes a retry for when it is shown
    /// (AgentPageCrashRetry; Leo, 2026-11-01: "why doens't it just retry on its own"). The pane,
    /// not the page host, decides (`reloadsAfterCrash` stays off).
    @Test func aHiddenCrashedChatRetriesWhenShown() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let view = try rig.hiddenChat("tab_crash", session: "s-crash")
        if let page = view.page { #expect(!page.reloadsAfterCrash, "the page host reloads a crashed chat itself") }
        view.webContentProcessDidTerminate()
        #expect(view.crashNotice == nil, "a crashed chat showed the notice instead of retrying")
        #expect(view.crashRetry.owed, "a hidden crashed chat owes no retry")
    }

    /// Even with a timeout written, a chat that kept crashing keeps its page and notice: a release
    /// would build it again when shown, a reload the person did not ask for.
    @Test func aCrashedChatIsNeverReleased() async throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .critical)
        let view = try rig.hiddenChat("tab_crashed", session: "s-crashed")
        // The injected end ends no real process: a document that finishes loading after it shows
        // the page lives and takes the notice away (pageLoadedAgain), so the load finishes first.
        if let page = view.page { await page.waitUntilLoaded() } else { await rig.settle { !view.webView.isLoading } }
        for _ in 0..<AgentPageCrashBudget.limit { _ = view.crashRetry.budget.ended(at: Date()) }
        view.webContentProcessDidTerminate()
        #expect(view.crashNotice != nil, "a chat that kept crashing showed no notice")
        rig.advance(minutes: 61)
        await rig.settle { rig.tabs.existingView("tab_crashed") == nil }
        #expect(rig.tabs.existingView("tab_crashed") === view, "a crashed chat was released and rebuilt")
        #expect(rig.hibernation.keepsPage("tab_crashed") == .unsupported)
    }

    /// With the acpmux turn watch down no chat's turn is known: every chat counts as busy and
    /// keeps its page until the watch is back.
    @Test func withTheTurnWatchDownEveryChatKeepsItsPage() async throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
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
