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
        /// The fronts the panes report (`BrowserHibernation.fronts`).
        var fronts: [String: HibernationPlanner.Front] = [:]

        init() {
            tabs = AgentTabStore(build: nil, registry: ActionRegistry(),
                                 environment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9/"], showcase: true)
            tabs.localHost = AgentPageHibernationTests.thisMac
            turns.localHost = AgentPageHibernationTests.thisMac
            turns.watching = true
            let tree = DaemonStore()
            hibernation = AgentPageHibernation(tabs: { [tabs] in tabs })
            // Weakly: a release still running after its test must not reach a freed rig.
            tabs.lookup = { [weak self] key in self?.records[key].map { ($0, tree) } }
            hibernation.turnState = { [weak self] key in
                guard let self, let record = self.records[key] else { return nil }
                return self.turns.state(for: record)
            }
            hibernation.turnsWatched = { [weak self] in self?.turns.watching ?? false }
            hibernation.followTurns(turns)
            hibernation.displace = { [weak self] key in self?.displaced.append(key) }
            let start = start
            hibernation.now = { [weak self] in start + (self?.elapsed ?? .zero) }
            hibernation.fronts = { [weak self] in self?.fronts ?? [:] }
            // The page never loads, so a snapshot of it is nil on some macOS and an image on others:
            // every release holds this frame instead, on every macOS, without the snapshot's 2 s deadline.
            let frame = Self.onePixel()
            hibernation.pageFrame = { _ in frame.map { (image: $0, size: NSSize(width: 1, height: 1), appearance: nil) } }
        }

        private static func onePixel() -> CGImage? {
            CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
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

        /// Waits for the releases in flight to end. A release still running at the cap is a
        /// failure, not a wait that runs out quietly and lets the release outlive its test.
        func settle(until done: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
            let deadline = ContinuousClock.now + .seconds(5)
            while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            if !done() { Issue.record("still waiting after 5 s (\(hibernation.releasingCount) releases in flight)", sourceLocation: sourceLocation) }
        }
    }

    @MainActor final class Asked { var count = 0 }
    @MainActor final class AskedPages { var count: [ObjectIdentifier: Int] = [:] }

    @Test func aChatHiddenPastTheThresholdLetsItsPageGoAndShowsTheSameChatAgain() async throws {
        let rig = Rig()
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        let page = try rig.hiddenChat("tab_quiet", session: "s-quiet")
        let busy = try rig.hiddenChat("tab_busy", session: "s-busy")
        rig.turns.setState(.working, session: "s-busy")

        // Moderate: half an hour hidden. At 20 minutes both pages stay.
        rig.advance(minutes: 20)
        await rig.settle { rig.hibernation.releasingCount == 0 }
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
        await rig.settle { rig.hibernation.releasingCount == 0 }
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
        #expect(asked.count == 1, "the page was not asked once (as it hid) what it held before it let go")

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
        await rig.settle { rig.hibernation.releasingCount == 0 }
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
        // BrowserHibernation holds the cache weakly: keep the services alive to the end.
        withExtendedLifetime((services, pane)) {}
    }

    /// A switch that parks a whole workspace (STRESS: 12 panes, a chat in front of each) moved
    /// every chat past the budget at once, and each release (wake state JS, a WKWebView snapshot
    /// and its encode, the retire) started in the same call, inside the switch's frames. They go
    /// at the browser pages' pace now: `Pace.perPass` at a time, the next after `Pace.interval`.
    @Test func chatsPastTheBudgetGoAFewAtATime() async throws {
        let rig = Rig()
        // The page never loads: answer at once, so a pass ends well before the next one is due.
        rig.hibernation.wakeState = { _ in nil }
        rig.hibernation.warmPages = { 4 }
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        let keys = (0..<12).map { "tab_parked_\($0)" }
        for key in keys {
            rig.fronts[key] = .parked
            _ = try rig.hiddenChat(key, session: "s-\(key)")
            rig.elapsed += .seconds(1)
        }
        rig.advance(minutes: 1.5)
        let perPass = HibernationPlanner.Pace.normal.perPass
        #expect(rig.hibernation.releasingCount == perPass, "8 chats past the budget started \(rig.hibernation.releasingCount) releases at once")
        #expect(rig.hibernation.nextCheck == HibernationPlanner.Pace.normal.interval, "no next pass for the chats still due")
        // More events in the same switch (every pane reports) start no more while a pass runs.
        rig.hibernation.frontsDidChange(Set(keys))
        rig.hibernation.replan()
        #expect(rig.hibernation.releasingCount == perPass, "a second event in the switch started more releases")
        await rig.settle { rig.hibernation.releasedCount == perPass && rig.hibernation.releasingCount == 0 }
        #expect(rig.hibernation.releasedCount == perPass)
        #expect(Set(rig.displaced) == Set(keys.prefix(perPass)), "the chats left longest ago did not go first")
        rig.hibernation.replan()
        #expect(rig.hibernation.releasingCount == perPass, "the next pass did not start")
        // A release counts as in flight until it ends, its frame's hold included (every release
        // here holds the rig's frame): it used to stop counting before that hold, so the pace
        // undercounted and this test ended while a release still ran.
        await rig.settle { rig.hibernation.releasingCount == 0 }
        #expect(rig.hibernation.releasedCount == 2 * perPass, "a release still ran after it stopped counting as in flight")
    }

    /// The chats check (16 chats in one pane, budget 13): 15 or 16 chat pages stayed live and one
    /// went. A connected page that does not say what it holds in time stays (its chips), but it
    /// stayed first in the budget order, so every pass asked it again and the chats past the
    /// budget behind it never went. A kept chat now steps out of the budget for
    /// `HibernationPlanner.keptHold`, as a browser page the probe kept: the next chat past the
    /// budget goes in the same pass, and the kept one is asked again after its hold. A kept page's
    /// frame is not taken.
    @Test func aChatThatDoesNotSayWhatItHoldsDoesNotHoldUpTheOthers() async throws {
        let rig = Rig()
        let asked = AskedPages()
        rig.hibernation.wakeState = { view in
            asked.count[ObjectIdentifier(view), default: 0] += 1
            return nil
        }
        let framed = AskedPages()
        rig.hibernation.pageFrame = { view in
            framed.count[ObjectIdentifier(view), default: 0] += 1
            return nil
        }
        rig.hibernation.warmPages = { 1 }
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        var quiet: [AgentPaneView] = []
        for key in ["tab_quiet_a", "tab_quiet_b", "tab_next", "tab_recent"] {
            let page = try rig.hiddenChat(key, session: "s-\(key)")
            if key.hasPrefix("tab_quiet") {
                // Connected: a page that does not answer keeps what it holds.
                _ = await page.model.respond(to: AgentPaneRequest(body: ["method": "ready", "params": ["reconnect": true]]))
                try #require(page.model.hasHandshake, "the reconnect handshake did not run")
                quiet.append(page)
            }
            rig.elapsed += .seconds(1)
        }
        let asks = { quiet.map { asked.count[ObjectIdentifier($0), default: 0] } }

        // Each was asked as it hid (no answer). The first pass asks the two chats left longest ago
        // again; both stay, and the first one kept starts the chat past the budget behind them in
        // the same pass.
        rig.advance(minutes: 1.5)
        await rig.settle { rig.hibernation.releasingCount == 0 }
        #expect(asks() == [2, 2], "the first pass did not ask the two chats left longest ago")
        #expect(rig.tabs.existingView("tab_quiet_a") === quiet[0] && rig.tabs.existingView("tab_quiet_b") === quiet[1],
                "a connected chat that did not say what it holds let its page go")
        #expect(quiet.allSatisfy { framed.count[ObjectIdentifier($0)] == nil }, "a chat that stays had its frame taken")
        #expect(rig.tabs.existingView("tab_next") == nil, "the kept chats held up the chat past the budget behind them")
        #expect(rig.tabs.existingView("tab_recent") != nil, "the chat inside the budget let its page go")

        // Another pass before their hold ends asks them nothing.
        rig.hibernation.replan()
        #expect(rig.hibernation.releasingCount == 0, "a pass asked the kept chats again before their hold ended")
        #expect(asks() == [2, 2])

        // After the hold they are asked again.
        rig.advance(minutes: HibernationPlanner.keptHold(times: 1) / 60 + 0.1)
        await rig.settle { rig.hibernation.releasingCount == 0 && asks() == [3, 3] }
        #expect(asks() == [3, 3], "the kept chats were not asked again after their hold")
        #expect(rig.tabs.existingView("tab_recent") != nil)
    }

    /// A release asked a chat what it held only when it went, a minute to half an hour after its
    /// hide, and a connected chat that did not answer then stayed. A hidden page answers late or
    /// not at all (background throttling, process suspension), so chats past the budget were kept
    /// again and again. The page is asked as it hides: a chat that answered then goes with what
    /// it held, and its hidden page is not asked again.
    @Test func aChatThatAnsweredAsItHidGoesWithoutAskingItsHiddenPage() async throws {
        let rig = Rig()
        let left = AgentPaneWakeState(shell: true, shellText: "make bench")
        let asked = Asked()
        rig.hibernation.wakeState = { _ in
            asked.count += 1
            // Hidden, it no longer answers.
            return asked.count == 1 ? left : nil
        }
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        let page = try rig.hiddenChat("tab_hid", session: "s-hid")
        _ = await page.model.respond(to: AgentPaneRequest(body: ["method": "ready", "params": ["reconnect": true]]))
        try #require(page.model.hasHandshake, "the reconnect handshake did not run")

        rig.advance(minutes: 31)
        await rig.settle { rig.hibernation.releasingCount == 0 }
        #expect(rig.tabs.existingView("tab_hid") == nil, "a chat that said what it held as it hid kept its page")
        #expect(asked.count == 1, "the release asked the hidden page again")

        let rebuilt = try #require(rig.tabs.view(for: "tab_hid"))
        #expect(rebuilt !== page)
        let reply = await rebuilt.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
        let handshake = try #require(reply["value"] as? [String: Any], "\(reply)")
        let wake = try #require(handshake["wake"] as? [String: Any], "the woken page lost what it held as it hid: \(handshake)")
        #expect(wake["shell"] as? Bool == true)
        #expect(wake["shellText"] as? String == "make bench")
    }

    /// A chat hidden ten minutes in front of the workspace left last (warm, out of the budget)
    /// starts to count when the person goes to a third workspace. It was due in that same turn,
    /// so its release landed in the switch and a quick switch back woke a page that was live a
    /// second before. The budget's minute runs from when it started to count.
    @Test func aChatFrontThatStartsToCountWaitsAMinute() async throws {
        let rig = Rig()
        rig.hibernation.warmPages = { 0 }
        rig.fronts["tab_front"] = .warm
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        let page = try rig.hiddenChat("tab_front", session: "s-front")
        rig.advance(minutes: 10)
        #expect(rig.hibernation.releasingCount == 0)

        rig.fronts["tab_front"] = .parked
        rig.hibernation.frontsDidChange(["tab_front"], becameCounted: ["tab_front"])
        #expect(rig.hibernation.releasingCount == 0, "a front that just started to count went in the turn of the switch")
        let next = try #require(rig.hibernation.nextCheck)
        #expect(abs(next - HibernationPlanner.overBudgetMinimumHidden) < 1e-6, "the minute did not run from when it started to count")
        #expect(rig.tabs.existingView("tab_front") === page)

        rig.advance(minutes: 1.1)
        await rig.settle { rig.tabs.existingView("tab_front") == nil }
        #expect(rig.tabs.existingView("tab_front") == nil, "the counted front kept its page past its minute")
    }

    /// With the acpmux turn watch down no chat's turn is known: every chat counts as busy and
    /// keeps its page until the watch is back.
    @Test func withTheTurnWatchDownEveryChatKeepsItsPage() async throws {
        let rig = Rig()
        rig.turns.watching = false
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        let page = try rig.hiddenChat("tab_unknown", session: "s-unknown")
        rig.advance(minutes: 61)
        await rig.settle { rig.hibernation.releasingCount == 0 }
        #expect(rig.tabs.existingView("tab_unknown") === page, "a chat whose turn nobody knows let its page go")
        #expect(rig.hibernation.keepsPage("tab_unknown") == .agentTurnsUnknown)

        // The watch is back and the chat idle: its overdue page goes without another hide.
        rig.turns.watching = true
        await rig.settle { rig.tabs.existingView("tab_unknown") == nil }
        #expect(rig.tabs.existingView("tab_unknown") == nil, "the watch came back and the idle chat kept its page")
    }
}
