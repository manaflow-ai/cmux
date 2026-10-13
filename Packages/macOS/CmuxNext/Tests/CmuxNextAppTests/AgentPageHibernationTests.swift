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
            tabs = AgentTabStore(tag: nil, registry: ActionRegistry(),
                                 environment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9/"], showcase: true)
            tabs.localHost = AgentPageHibernationTests.thisMac
            turns.localHost = AgentPageHibernationTests.thisMac
            let tree = DaemonStore()
            hibernation = AgentPageHibernation(tabs: { [tabs] in tabs })
            tabs.lookup = { [unowned self] key in self.records[key].map { ($0, tree) } }
            hibernation.turnState = { [unowned self] key in self.records[key].flatMap(self.turns.state(for:)) }
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

    @Test func aChatHiddenPastTheThresholdLetsItsPageGoAndShowsTheSameChatAgain() async throws {
        let rig = Rig()
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        let page = try rig.hiddenChat("tab_quiet", session: "s-quiet")
        let busy = try rig.hiddenChat("tab_busy", session: "s-busy")
        _ = rig.turns.states.set("s-busy", .working)

        // Moderate: an hour hidden. At half an hour both pages stay.
        rig.advance(minutes: 30)
        await rig.settle { false }
        #expect(rig.tabs.existingView("tab_quiet") === page)

        rig.advance(minutes: 31)
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
}
