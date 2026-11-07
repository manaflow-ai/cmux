import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextSettings
import Testing

/// `agents.hiddenChats.discard` (Leo, 2026-11-07: "but is there a smarter way to discard? like if it
/// really isn't being used after a while, can't things be more aggressive?"): with it on, a hidden idle
/// agent chat lets its page go after `afterMinutes` without `browser.hibernation`, the least recently
/// seen first, sooner under memory pressure, and never while its composer holds a draft. Off, chats
/// behave as before. ``HiddenChatPages`` through a host that records what it is asked to do.
@MainActor @Suite struct HiddenChatDiscardTests {
    /// The App's side as the planner sees it: every page may go, none draws, none freezes. A release
    /// is queued as the App's runs in a task; ``finish()`` runs them as the App does after the page answers.
    @MainActor final class Host: HiddenChatPagesHost {
        final class Page {}
        var pages: [String: Page] = [:]
        let start = ContinuousClock.now
        var elapsed: Duration = .zero
        var busy: Set<String> = []
        /// Chats whose composer holds a draft (the page's `holdsDraft`).
        var drafts: Set<String> = []
        /// Chats whose page holds an edit outside the composer (the page's `holdsEdits`).
        var edits: Set<String> = []
        /// Releases asked for, in order.
        var requested: [String] = []
        var released: [String] = []
        var kept: [String: String] = [:]
        weak var planner: HiddenChatPages<Host>?

        func hibernationPages() -> [String: Page]? { pages }
        func hibernationPage(_ key: String) -> Page? { pages[key] }
        func pageDraws(_ key: String) -> Bool { false }
        func pageClock() -> ContinuousClock.Instant { start + elapsed }
        func pagePinned(_ key: String) -> Bool { false }
        func pageTurnsKnown() -> Bool { true }
        func pageTurnBusy(_ key: String) -> Bool { busy.contains(key) }
        func pageMayRelease(_ key: String, onScreen: Bool) -> Bool { true }
        func pageIsUntouchedNewTab(_ key: String) -> Bool { false }
        func pageMayFreeze(_ key: String, onScreen: Bool) -> Bool { false }
        func freezeControl(of page: Page) -> Int? { nil }
        func setFrozen(_ control: Int, _ frozen: Bool) -> Bool { true }
        func setPageWork(_ page: Page, _ work: (@MainActor () -> Void)?) {}
        func releasePage(_ key: String) { requested.append(key) }
        func dropReleasedFrame(_ key: String) {}

        /// Runs the queued releases as `AgentPageHibernation.releasePage` does: begin, ask the page what
        /// it holds, keep it or let it go.
        func finish() {
            let queue = requested
            requested = []
            for key in queue {
                guard let planner, let started = planner.beginRelease(key) else { continue }
                planner.endRelease(key)
                let wake = AgentPaneWakeState(holdsDraft: drafts.contains(key), holdsEdits: edits.contains(key))
                if let reason = AgentPaneWakeState.keepReason(wake, hasHandshake: true, keepsDraft: started.byChatPolicy) {
                    kept[key] = reason
                    planner.keptForNow(key)
                    continue
                }
                guard let page = pages[key], planner.isDue(key, page: page) else { continue }
                pages[key] = nil
                planner.released(key)
                released.append(key)
            }
        }
    }

    /// A deadline that never fires: each test plans itself.
    final class Deadline: WorkspaceHibernationDeadline, @unchecked Sendable { // test-only; touched on the main actor alone
        var isScheduled = false
        func schedule(after delay: Duration, _ action: @escaping @isolated(any) @Sendable () async -> Void) { isScheduled = true }
        func cancel() { isScheduled = false }
    }

    static func make(_ discard: HiddenChatDiscardSetting, setting: BrowserHibernationSetting = .fallback,
                     pressure: MemoryPressureLevel = .normal) -> (HiddenChatPages<Host>, Host) {
        let host = Host()
        let planner = HiddenChatPages(host: host, deadline: Deadline(), freezeDeadline: Deadline())
        host.planner = planner
        planner.update(setting: setting, pressure: pressure)
        planner.update(discard: discard)
        return (planner, host)
    }

    /// Chat `key` hidden now.
    static func hide(_ key: String, _ planner: HiddenChatPages<Host>, _ host: Host) {
        host.pages[key] = Host.Page()
        planner.pageVisibility(key, visible: false)
    }

    static func advance(_ seconds: Double, _ planner: HiddenChatPages<Host>, _ host: Host) {
        host.elapsed += .seconds(seconds)
        planner.replan()
        host.finish()
    }

    @Test func aHiddenIdleChatGoesAfterItsMinutesWithoutBrowserHibernation() {
        let (planner, host) = Self.make(HiddenChatDiscardSetting(enabled: true, afterMinutes: 15))
        Self.hide("tab_quiet", planner, host)
        Self.hide("tab_busy", planner, host)
        host.busy = ["tab_busy"]
        #expect(planner.hasDeadline, "the hide armed no deadline")

        Self.advance(14 * 60, planner, host)
        #expect(host.released.isEmpty, "released before its minutes")

        Self.advance(61, planner, host)
        #expect(host.released == ["tab_quiet"], "the hidden idle chat kept its page with browser.hibernation unset")
        #expect(planner.keepsPage("tab_busy") == .agentBusy, "a chat whose agent works was let go")
    }

    @Test func offKeepsEveryChatAsBefore() {
        let (planner, host) = Self.make(.off)
        Self.hide("tab_quiet", planner, host)
        Self.advance(24 * 60 * 60, planner, host)
        #expect(host.released.isEmpty, "a chat went with the setting off and browser.hibernation unset")
        #expect(planner.keepsPage("tab_quiet") == .keepsState)
        #expect(!planner.hasDeadline)

        // browser.hibernation off and the policy off: disabled, as before.
        planner.update(setting: BrowserHibernationSetting(mode: .off), pressure: .critical)
        #expect(planner.keepsPage("tab_quiet") == .disabled)
    }

    @Test func theLeastRecentlySeenChatGoesFirst() {
        let (planner, host) = Self.make(HiddenChatDiscardSetting(enabled: true, afterMinutes: 1))
        let order = ["tab_c", "tab_a", "tab_e", "tab_b", "tab_f", "tab_d"]
        for key in order {
            Self.hide(key, planner, host)
            host.elapsed += .seconds(5)
        }
        // All due at once: asked oldest hidden first.
        host.elapsed += .seconds(10 * 60)
        planner.replan()
        #expect(host.requested == order, "released out of least-recently-seen order: \(host.requested)")
    }

    @Test func memoryPressureShortensTheWait() {
        let (planner, host) = Self.make(HiddenChatDiscardSetting(enabled: true, afterMinutes: 30), pressure: .warning)
        Self.hide("tab_warned", planner, host)
        Self.advance(4 * 60, planner, host)
        #expect(host.released.isEmpty, "warning pressure released before 5 minutes")
        Self.advance(61, planner, host)
        #expect(host.released == ["tab_warned"], "warning pressure waited the full 30 minutes")

        // Critical: at once, past the composer's short wait.
        planner.update(setting: .fallback, pressure: .critical)
        Self.hide("tab_pressed", planner, host)
        Self.advance(HiddenChatPages<Host>.minimumHidden / 2, planner, host)
        #expect(!host.released.contains("tab_pressed"), "released before the composer's last keystrokes reached acpmux")
        Self.advance(HiddenChatPages<Host>.minimumHidden, planner, host)
        #expect(host.released.contains("tab_pressed"), "critical pressure kept a hidden chat")
    }

    @Test func aDraftKeepsTheChatOnlyWhenThePolicyMadeItDue() {
        let (planner, host) = Self.make(HiddenChatDiscardSetting(enabled: true, afterMinutes: 5))
        Self.hide("tab_draft", planner, host)
        host.drafts = ["tab_draft"]
        Self.advance(6 * 60, planner, host)
        #expect(host.released.isEmpty, "a chat holding a draft was let go")
        #expect(host.kept["tab_draft"] == "holds a draft")
        #expect(planner.hasDeadline, "a kept chat is asked again")

        // The draft is sent: asked again after the recheck, it goes.
        host.drafts = []
        Self.advance(HiddenChatPages<Host>.keptRecheck + 1, planner, host)
        #expect(host.released == ["tab_draft"])

        // browser.hibernation releasing on its own is unchanged: its release takes no draft veto.
        let (byBrowser, browserHost) = Self.make(HiddenChatDiscardSetting(enabled: true, afterMinutes: 60),
                                                 setting: BrowserHibernationSetting(mode: .aggressive))
        Self.hide("tab_browser", byBrowser, browserHost)
        browserHost.drafts = ["tab_browser"]
        Self.advance(11 * 60, byBrowser, browserHost)
        #expect(browserHost.released == ["tab_browser"], "browser.hibernation's own release changed")
    }

    /// Review F1 on #37895: a queued message being edited lives only in the page, with the composer empty.
    @Test func anUnsavedEditKeepsTheChatOnlyWhenThePolicyMadeItDue() {
        let (planner, host) = Self.make(HiddenChatDiscardSetting(enabled: true, afterMinutes: 5))
        Self.hide("tab_edit", planner, host)
        host.edits = ["tab_edit"]
        Self.advance(6 * 60, planner, host)
        #expect(host.released.isEmpty, "a chat holding an unsaved edit was let go")
        #expect(host.kept["tab_edit"] == "holds an unsaved edit")

        host.edits = []
        Self.advance(HiddenChatPages<Host>.keptRecheck + 1, planner, host)
        #expect(host.released == ["tab_edit"])

        let (byBrowser, browserHost) = Self.make(HiddenChatDiscardSetting(enabled: true, afterMinutes: 60),
                                                 setting: BrowserHibernationSetting(mode: .aggressive))
        Self.hide("tab_browser", byBrowser, browserHost)
        browserHost.edits = ["tab_browser"]
        Self.advance(11 * 60, byBrowser, browserHost)
        #expect(browserHost.released == ["tab_browser"], "browser.hibernation's own release changed")
    }
}
