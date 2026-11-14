@testable import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextSettings
import Testing

/// A chat that is not drawn and is proven idle gives back its memory; an archived one always does; a
/// working one keeps it (Leo, 2026-11-14: "archived chats (ok well THOSE should defo release ram)";
/// "obviously if something isn't drawn/is completely proven idle then dont bother taking memory... but
/// if it's working then you can try to optimize but thats it"). Always on, with no setting (Lawrence,
/// #38022). ``HiddenChatPages`` through a host that records what it is asked to do.
@MainActor @Suite struct IdleChatReleaseTests {
    /// The App's side as the planner sees it: every page may go, none draws, none freezes. A release
    /// is queued as the App's runs in a task; ``finish()`` runs them as the App does after the page answers.
    @MainActor final class Host: HiddenChatPagesHost {
        final class Page {}
        var pages: [String: Page] = [:]
        let start = ContinuousClock.now
        var elapsed: Duration = .zero
        var busy: Set<String> = []
        var archived: Set<String> = []
        /// Chats whose page holds an unsaved send or edit (the page's `holdsEdits`).
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
        func pageArchived(_ key: String) -> Bool { archived.contains(key) }
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
                guard let planner, planner.beginRelease(key) != nil else { continue }
                planner.endRelease(key)
                let wake = AgentPaneWakeState(holdsEdits: edits.contains(key))
                if let reason = AgentPaneWakeState.keepReason(wake, hasHandshake: true) {
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

    static func make(setting: BrowserHibernationSetting = .fallback, pressure: MemoryPressureLevel = .normal) -> (HiddenChatPages<Host>, Host) {
        let host = Host()
        let planner = HiddenChatPages(host: host, deadline: Deadline(), freezeDeadline: Deadline())
        host.planner = planner
        planner.update(setting: setting, pressure: pressure)
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

    static var idle: Double { HiddenChatPages<Host>.idleRelease }

    /// No setting written: a hidden idle chat gives back its page after ``HiddenChatPages/idleRelease``.
    @Test func aHiddenIdleChatGivesBackItsPageByDefault() {
        let (planner, host) = Self.make()
        Self.hide("tab_quiet", planner, host)
        #expect(planner.hasDeadline, "the hide armed no deadline")

        Self.advance(Self.idle - 5, planner, host)
        #expect(host.released.isEmpty, "released before the idle wait: a look away and back rebuilds the page")

        Self.advance(6, planner, host)
        #expect(host.released == ["tab_quiet"], "a hidden idle chat kept its page by default")
    }

    /// `browser.hibernation` off is about browser tabs: a hidden idle chat still gives back its page.
    @Test func browserHibernationOffStillLetsAnIdleChatGo() {
        let (planner, host) = Self.make(setting: BrowserHibernationSetting(mode: .off))
        Self.hide("tab_quiet", planner, host)
        Self.advance(Self.idle + 1, planner, host)
        #expect(host.released == ["tab_quiet"], "browser.hibernation off kept a hidden idle chat's page")
    }

    /// An archived chat's hidden page goes at once, before the idle wait and the composer's short wait.
    @Test func anArchivedChatGivesBackItsPageAtOnce() {
        let (planner, host) = Self.make()
        Self.hide("tab_archived", planner, host)
        Self.hide("tab_kept", planner, host)
        host.archived = ["tab_archived"]
        Self.advance(1, planner, host)
        #expect(host.released == ["tab_archived"], "an archived hidden chat kept its page: \(host.released)")

        // Archived but working: it keeps its page until the work ends.
        Self.hide("tab_archived_busy", planner, host)
        host.archived.insert("tab_archived_busy")
        host.busy = ["tab_archived_busy"]
        Self.advance(1, planner, host)
        #expect(!host.released.contains("tab_archived_busy"), "an archived chat that still works was let go")
        #expect(planner.keepsPage("tab_archived_busy") == .agentBusy)
        host.busy = []
        Self.advance(0, planner, host)
        #expect(host.released.contains("tab_archived_busy"))
    }

    /// A working chat (its turn runs, it waits on a permission, a subagent or command runs) keeps its page
    /// however long it is hidden and whatever the pressure; it goes once the work ends.
    @Test(arguments: [MemoryPressureLevel.normal, .warning, .critical])
    func aWorkingChatKeepsItsPage(_ pressure: MemoryPressureLevel) {
        let (planner, host) = Self.make(pressure: pressure)
        Self.hide("tab_working", planner, host)
        host.busy = ["tab_working"]
        Self.advance(24 * 60 * 60, planner, host)
        #expect(host.released.isEmpty, "a working chat was let go")
        #expect(planner.keepsPage("tab_working") == .agentBusy)

        host.busy = []
        Self.advance(0, planner, host)
        #expect(host.released == ["tab_working"], "a chat whose work ended kept its page")
    }

    /// What acpmux says decides whether a chat works: its turn, a permission or question, or a subagent
    /// or background command it started. Only a chat doing none of these is idle.
    @Test func aChatIsIdleOnlyWhenNothingOfItRuns() {
        #expect(AgentTurnState.isWorking(.working, detail: nil))
        #expect(AgentTurnState.isWorking(.needsInput, detail: nil), "a pending permission or tool question is work")
        #expect(AgentTurnState.isWorking(nil, detail: AgentChatDetail(subagentsRunning: 1)), "a running subagent is work")
        #expect(AgentTurnState.isWorking(.done, detail: AgentChatDetail(commandsRunning: 2)), "a running background command is work")
        #expect(!AgentTurnState.isWorking(nil, detail: nil))
        #expect(!AgentTurnState.isWorking(.done, detail: AgentChatDetail(model: "m")))
        #expect(!AgentTurnState.isWorking(.failed, detail: AgentChatDetail()))
    }

    /// acpmux's `archived` tag reaches the chat's detail, in each shape the summary carries it.
    @Test func theArchiveTagIsReadFromTheSummary() {
        #expect(AgentChatDetail.of(summary: ["tags": ["archived": "1"]])?.archived == true)
        #expect(AgentChatDetail.of(summary: ["tags": ["archived": ["value": "1"]]])?.archived == true)
        #expect(AgentChatDetail.archived(["tags": ["archived": ["value": "1", "expires_at": 10] as [String: Any]]], nowMs: 20) == false)
        #expect(AgentChatDetail.archived(["tags": ["archived": ["value": "1", "expires_at": 30] as [String: Any]]], nowMs: 20) == true)
        #expect(AgentChatDetail.of(summary: ["tags": ["notifications": "muted"]])?.archived != true)
        #expect(AgentChatDetail.of(summary: ["model": "m"])?.archived == false)
    }

    /// A released idle chat that kept only its scroll place opens again in the prewarmed spare page, with that
    /// place on the adopt event; one that kept chips, shell text or folds gets a page of its own, which its
    /// handshake hands them to.
    @Test func aReleasedChatHoldingOnlyItsPlaceTakesTheSpare() {
        let anchor = AgentPaneScrollAnchor(rowId: "row-3", offset: 9)
        let placeOnly = AgentPaneWakeState(scrollAnchor: anchor)
        #expect(placeOnly.holdsOnlyPlace)
        #expect(placeOnly.place == .some(anchor))
        #expect(AgentPaneWakeState(atLatest: true).holdsOnlyPlace)
        #expect(AgentPaneWakeState(atLatest: true).place == .some(nil), "a chat left at its latest message reopens there")
        #expect(AgentPaneWakeState().place == nil)
        #expect(!AgentPaneWakeState(shell: true, shellText: "ls", atLatest: true).holdsOnlyPlace)
        #expect(!AgentPaneWakeState(folds: .init(session: "s", expanded: ["t1"]), atLatest: true).holdsOnlyPlace)

        let adoption = { (wake: AgentPaneWakeState?) in
            AgentPaneSpareAdoption(thisMac: true, session: "s-1", newTabPage: false, seeded: false,
                                   wake: wake.map { !$0.holdsOnlyPlace } ?? false).adopted(chiefKeeps: { _ in false })
        }
        #expect(adoption(placeOnly) == "s-1", "a released chat with only its place built a page from nothing")
        #expect(adoption(AgentPaneWakeState(shellText: "make", scrollAnchor: anchor)) == nil)
        let detail = AgentPaneView.adoptEventDetail(session: "s-1", revealTurn: nil, tail: nil, place: placeOnly.place)
        #expect(detail.contains("row-3"), "the adopt event lost the released chat's place: \(detail)")
    }

    @Test func theLeastRecentlySeenChatGoesFirst() {
        let (planner, host) = Self.make()
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
        let (planner, host) = Self.make(pressure: .warning)
        Self.hide("tab_warned", planner, host)
        Self.advance(HiddenChatPages<Host>.idleReleaseUnderWarning - 5, planner, host)
        #expect(host.released.isEmpty, "warning pressure released before its wait")
        Self.advance(6, planner, host)
        #expect(host.released == ["tab_warned"], "warning pressure waited the full idle wait")

        // Critical: at once, past the composer's short wait.
        planner.update(setting: .fallback, pressure: .critical)
        Self.hide("tab_pressed", planner, host)
        Self.advance(HiddenChatPages<Host>.minimumHidden / 2, planner, host)
        #expect(!host.released.contains("tab_pressed"), "released before the composer's last keystrokes reached acpmux")
        Self.advance(HiddenChatPages<Host>.minimumHidden, planner, host)
        #expect(host.released.contains("tab_pressed"), "critical pressure kept a hidden chat")
    }

    /// A draft is not a reason to keep: the page settles it into acpmux before it answers, and it comes
    /// back with the page built on reopen. An unsaved send or edit the page alone holds keeps it, under
    /// every release (`browser.hibernation`'s too), until it is saved: nothing typed is lost.
    @Test func anUnsavedSendOrEditKeepsThePageUntilItIsSaved() {
        let (planner, host) = Self.make()
        Self.hide("tab_edit", planner, host)
        host.edits = ["tab_edit"]
        Self.advance(Self.idle + 1, planner, host)
        #expect(host.released.isEmpty, "a chat holding an unsaved send or edit was let go")
        #expect(host.kept["tab_edit"] == "holds an unsaved edit")
        #expect(planner.hasDeadline, "a kept chat is asked again")

        host.edits = []
        Self.advance(HiddenChatPages<Host>.keptRecheck + 1, planner, host)
        #expect(host.released == ["tab_edit"])

        let (byBrowser, browserHost) = Self.make(setting: BrowserHibernationSetting(mode: .aggressive))
        Self.hide("tab_browser", byBrowser, browserHost)
        browserHost.edits = ["tab_browser"]
        Self.advance(11 * 60, byBrowser, browserHost)
        #expect(browserHost.released.isEmpty, "browser.hibernation's release dropped an unsaved edit")
    }
}
