import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHibernation
import CmuxNextInput
@testable import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextWakeups
import Foundation
import Testing

/// With `pageLifecycle` on, agent chats and New Tab pages are pages of the page
/// lifecycle. Its planner freezes and discards them with every exemption AgentPageHibernation kept: a
/// running turn blocks both, a draft blocks the discard, and an untouched New Tab page is let go at the
/// planner's 300 s. The lifecycle runs on a deadline scheduler whose uptime only the test moves, and each
/// pass runs when the test calls it, so no test waits on a clock.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct AgentPageHibernationLifecycleTests {
    static let thisMac = "install:agent-page-lifecycle-test"

    @MainActor final class Rig {
        let tabs: AgentTabStore
        let hibernation: AgentPageHibernation
        let lifecycle: PageLifecycle
        let turns = AgentTurnStateStore()
        var records: [String: AgentSessionRef] = [:]
        var displaced: [String] = []
        var released = 0
        private let uptime: LifecycleRigUptime

        init(wake: AgentPaneWakeState? = nil) {
            tabs = AgentTabStore(build: nil, registry: ActionRegistry(), work: BackgroundWork(label: "test.agent-pane"), webUI: .agentTabsTestHost(), input: InputEventTap(),
                                 environment: AgentPageAppTestRoot.environment, showcase: true)
            tabs.localHost = AgentPageHibernationLifecycleTests.thisMac
            turns.localHost = AgentPageHibernationLifecycleTests.thisMac
            turns.watching = true
            let tree = DaemonStore()
            hibernation = AgentPageHibernation(tabs: { [tabs] in tabs }, deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())))
            let uptime = LifecycleRigUptime()
            self.uptime = uptime
            let queue = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: WakeupLedger(uptime: { 0 }),
                                        uptime: { uptime.now }) { _ in LifecycleRigTimer() }
            lifecycle = PageLifecycle(conditions: .init(setting: BrowserHibernationSetting(mode: .moderate)),
                                      deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()), queue: queue))
            tabs.lookup = { [unowned self] key in self.records[key].map { ($0, tree) } }
            hibernation.turnState = { [unowned self] key in self.records[key].flatMap(self.turns.state(for:)) }
            hibernation.turnsWatched = { [unowned self] in self.turns.watching }
            hibernation.wakeState = { _ in wake }
            // The test's pages never finish loading; loading is PageLifecycleTests' reason, not the agent's.
            hibernation.pageFacts = { _ in [] }
            hibernation.displace = { [unowned self] key in self.displaced.append(key) }
            hibernation.onRelease = { [unowned self] in self.released += 1 }
            hibernation.followTurns(turns)
            hibernation.follow(lifecycle)
        }

        /// A chat of this Mac on `session`.
        func chat(_ key: String, session: String) throws -> AgentPaneView {
            records[key] = AgentSessionRef(host: AgentPageHibernationLifecycleTests.thisMac, hostName: "This Mac", session: session, harness: "claude")
            return try #require(tabs.view(for: key), "no page for \(key)")
        }

        /// A New Tab page of this Mac (no chat yet).
        func newTab(_ key: String) throws -> AgentPaneView {
            records[key] = AgentSessionRef(host: AgentPageHibernationLifecycleTests.thisMac, hostName: "This Mac", session: nil, harness: nil)
            tabs.newTabPages[key] = (AgentPaneNewTab(kind: .agent), NewTabPageHandler(open: { _, _ in }, jump: { _, _, _ in }, editShortcut: { _ in }))
            let view = try #require(tabs.view(for: key), "no page for \(key)")
            #expect(view.model.newTab != nil)
            return view
        }

        /// The tab shows, then hides at `at` seconds, as its content lifecycle's reveal and conceal call the
        /// page lifecycle; returns once the hide read answered.
        func showThenHide(_ key: String, at seconds: Double) async {
            advance(to: seconds)
            lifecycle.tabDidShow(key)
            lifecycle.tabDidHide(key)
            await settle { self.hibernation.hideReads[key]?.isDone == true }
        }

        func advance(to seconds: Double) { uptime.now = UInt64(seconds * 1e9) }

        /// One planner pass at `seconds`.
        func pass(at seconds: Double) {
            advance(to: seconds)
            lifecycle.runPass()
        }

        /// Waits for an async step: the hide read, or the turn observation handing a change on.
        func settle(until done: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(5)
            while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    @Test func aRunningHiddenChatIsNeitherFrozenNorDiscardedAndGoesOnceItsTurnEnds() async throws {
        let rig = Rig()
        let running = try rig.chat("tab_running", session: "s-running")
        _ = try rig.chat("tab_idle", session: "s-idle")
        _ = try rig.chat("tab_last", session: "s-last")
        rig.turns.setState(.working, session: "s-running")
        await rig.showThenHide("tab_running", at: 0)
        await rig.showThenHide("tab_idle", at: 0)
        await rig.showThenHide("tab_last", at: 1) // the most recently used: never frozen

        rig.pass(at: 12)
        #expect(rig.lifecycle.state(of: "tab_running") == .hidden, "a chat whose turn runs was frozen")
        #expect(rig.lifecycle.state(of: "tab_idle") == .frozen, "an idle hidden chat did not freeze")
        #expect(rig.lifecycle.state(of: "tab_last") == .hidden)

        for seconds in stride(from: 305.0, through: 330, by: 5) { rig.pass(at: seconds) }
        #expect(rig.lifecycle.state(of: "tab_running") == .hidden, "a chat whose turn runs was discarded")
        #expect(rig.tabs.existingView("tab_running") === running)
        #expect(rig.tabs.existingView("tab_idle") == nil, "the idle chat kept its page past 300 s")
        #expect(rig.tabs.existingView("tab_last") == nil)
        #expect(Set(rig.displaced) == ["tab_idle", "tab_last"])
        #expect(rig.released == 2)
        #expect(rig.tabs.session(of: "tab_idle") == "s-idle", "a let-go chat lost its session")

        // The turn ends: the lifecycle hears it with no hide or show, and the overdue page goes.
        rig.turns.setState(.done, session: "s-running")
        await rig.settle { rig.lifecycle.nextPassAt != nil }
        let due = try #require(rig.lifecycle.nextPassAt, "the turn's end armed no pass")
        rig.pass(at: Double(due.components.seconds) + 1)
        #expect(rig.tabs.existingView("tab_running") == nil, "the chat kept its page after its turn ended")
        #expect(rig.lifecycle.state(of: "tab_running") == .discarded)
    }

    /// A turn that starts on a frozen hidden chat thaws it in that turn: acpmux cannot resync a frozen
    /// page's stream yet. A chat waiting on the person may freeze but is never discarded.
    @Test func aTurnThatStartsThawsAFrozenChatAndWaitingOnThePersonKeepsIt() async throws {
        let rig = Rig()
        _ = try rig.chat("tab_a", session: "s-a")
        _ = try rig.chat("tab_b", session: "s-b")
        await rig.showThenHide("tab_a", at: 0)
        await rig.showThenHide("tab_b", at: 1)
        rig.pass(at: 12)
        #expect(rig.lifecycle.state(of: "tab_a") == .frozen)

        rig.turns.setState(.working, session: "s-a")
        await rig.settle { rig.lifecycle.state(of: "tab_a") == .hidden }
        #expect(rig.lifecycle.state(of: "tab_a") == .hidden, "a turn started on a frozen chat and it stayed frozen")

        // Its turn waits on the person now: handed on at once (the observation would hand on the same).
        rig.turns.setState(.needsInput, session: "s-a")
        rig.hibernation.refreshTurnReasons()
        for seconds in stride(from: 305.0, through: 330, by: 5) { rig.pass(at: seconds) }
        #expect(rig.tabs.existingView("tab_a") != nil, "a chat waiting on the person was let go")
        #expect(rig.lifecycle.state(of: "tab_a") == .frozen, "a chat waiting on the person may freeze")
        #expect(rig.tabs.existingView("tab_b") == nil)
    }

    /// An idle chat that freezes lets its acpmux connection go, and its thaw (a turn started)
    /// hands its page the close it reconnects on. A chat waiting on the person keeps its connection, and so
    /// does one whose hide read did not answer.
    @Test func aFrozenIdleChatClosesItsConnectionAndItsThawHandsOnTheClose() async throws {
        let rig = Rig(wake: AgentPaneWakeState())
        let idle = try rig.chat("tab_idle", session: "s-idle")
        let asking = try rig.chat("tab_asking", session: "s-asking")
        _ = try rig.chat("tab_last", session: "s-last")
        for pane in [idle, asking] { Self.connect(pane) }
        rig.turns.setState(.needsInput, session: "s-asking")
        await rig.showThenHide("tab_idle", at: 0)
        await rig.showThenHide("tab_asking", at: 0)
        await rig.showThenHide("tab_last", at: 1)

        rig.pass(at: 12)
        #expect(rig.lifecycle.state(of: "tab_idle") == .frozen)
        #expect(rig.lifecycle.state(of: "tab_asking") == .frozen)
        #expect(idle.model.transport.closedForFreeze == 1, "a frozen idle chat kept its acpmux connection")
        #expect(asking.model.transport.closedForFreeze == nil, "a frozen chat waiting on the person lost its connection")

        // A turn starts on the idle chat: it thaws in that turn and its page gets the close, once.
        var closes: [String] = []
        idle.model.transport.deliver = { event, done in
            if let closed = event.closed { closes.append(closed.reason) }
            done()
        }
        rig.turns.setState(.working, session: "s-idle")
        await rig.settle { closes.count == 1 }
        #expect(rig.lifecycle.state(of: "tab_idle") == .hidden)
        #expect(closes == [AgentPaneTransport.pageFrozenCloseReason], "the thawed chat's page did not get the freeze's close")
        #expect(idle.model.transport.connection == nil)

        // No answer to the hide read: what the page holds is unknown, so its connection stays.
        rig.hibernation.wakeState = { _ in nil }
        let unread = try rig.chat("tab_unread", session: "s-unread")
        Self.connect(unread)
        await rig.showThenHide("tab_unread", at: 20)
        _ = try rig.chat("tab_after", session: "s-after")
        await rig.showThenHide("tab_after", at: 21)
        rig.pass(at: 40)
        #expect(rig.lifecycle.state(of: "tab_unread") == .frozen)
        #expect(unread.model.transport.closedForFreeze == nil, "a chat that did not answer its hide read lost its connection")
    }

    /// A chat that froze while it waited on the person keeps its connection; once the question goes away
    /// with no turn running (the turn ended elsewhere), the still frozen page lets the connection go.
    @Test func aFrozenChatWhoseQuestionWentAwayClosesItsConnection() async throws {
        let rig = Rig(wake: AgentPaneWakeState())
        let asking = try rig.chat("tab_asking", session: "s-asking")
        _ = try rig.chat("tab_last", session: "s-last")
        Self.connect(asking)
        rig.turns.setState(.needsInput, session: "s-asking")
        await rig.showThenHide("tab_asking", at: 0)
        await rig.showThenHide("tab_last", at: 1)
        rig.pass(at: 12)
        #expect(rig.lifecycle.state(of: "tab_asking") == .frozen)
        #expect(asking.model.transport.closedForFreeze == nil, "a frozen chat waiting on the person lost its connection")

        // Handed on at once (the observation would hand on the same).
        rig.turns.setState(.done, session: "s-asking")
        rig.hibernation.refreshTurnReasons()
        #expect(rig.lifecycle.state(of: "tab_asking") == .frozen)
        #expect(asking.model.transport.closedForFreeze == 1, "a frozen idle chat kept its acpmux connection")
    }

    /// Gives `pane` a connection 1 whose socket never connects. Its wake reaches the transport as an open
    /// socket's does (``AgentPaneTransport/open(_:)``), so the close reaches the pacer.
    static func connect(_ pane: AgentPaneView) {
        let transport = pane.model.transport
        transport.socket = AcpmuxPaneSocket(request: URLRequest(url: URL(string: "ws://127.0.0.1")!), limits: transport.limits,
                                            options: transport.permissionOptions, sessions: transport.sessions,
                                            ids: AcpmuxRequestIds()) { [weak transport] in
            // task-owner: one wake for the pacer, as the transport's own socket gives
            Task { @MainActor [weak transport] in transport?.arrived(1) }
        }
        transport.current = 1
    }

    /// An untouched hidden New Tab page goes at 300 s, not before, and its tab shows the New Tab page
    /// again. One the person typed into keeps its page.
    @Test func anUntouchedHiddenNewTabIsDiscardedAt300Seconds() async throws {
        let rig = Rig()
        let page = try rig.newTab("tab_new")
        _ = try rig.newTab("tab_typed")
        rig.tabs.unsentDrafts.set("half a question", for: "tab_typed")
        await rig.showThenHide("tab_typed", at: 0)
        await rig.showThenHide("tab_new", at: 0)

        rig.pass(at: 12)
        rig.pass(at: 299)
        #expect(rig.tabs.existingView("tab_new") === page, "the New Tab page went before 300 s")
        rig.pass(at: 300)
        #expect(rig.lifecycle.state(of: "tab_new") == .discarded)
        #expect(rig.tabs.existingView("tab_new") == nil, "the untouched New Tab page kept its page at 300 s")
        #expect(rig.tabs.newTabPages["tab_new"] != nil, "the tab forgot it shows the New Tab page")
        let rebuilt = try #require(rig.tabs.view(for: "tab_new"))
        #expect(rebuilt !== page)
        #expect(rebuilt.model.newTab != nil, "the tab came back as a chat, not the New Tab page")

        rig.pass(at: 600)
        #expect(rig.tabs.existingView("tab_typed") != nil, "a New Tab page with typed text was let go")
        #expect(rig.lifecycle.state(of: "tab_typed") != .discarded)
    }

    /// The discard asks the page nothing: what it held is read at its hide and handed to the page its
    /// next show builds.
    @Test func theDiscardHandsOnWhatTheHideRead() async throws {
        let left = AgentPaneWakeState(shell: true, shellText: "git status")
        let rig = Rig(wake: left)
        _ = try rig.chat("tab_left", session: "s-left")
        await rig.showThenHide("tab_left", at: 0)
        #expect(rig.hibernation.hideReads["tab_left"]?.isDone == true)
        rig.hibernation.wakeState = { _ in
            Issue.record("the discard asked the page what it held")
            return nil
        }
        rig.pass(at: 12)
        rig.pass(at: 300)
        #expect(rig.tabs.existingView("tab_left") == nil)
        #expect(rig.tabs.wakeStates["tab_left"] == left, "the hide's read did not reach the rebuilt page")
    }

    /// A New Tab page where a model or mode chip pick started a chat no prompt went to keeps its page:
    /// only the page knows that chat, and letting it go would lose the pick. The page says so in its hide
    /// read (`pendingChat`).
    @Test func aNewTabWhoseChipPickStartedAChatKeepsItsPage() async throws {
        let rig = Rig(wake: AgentPaneWakeState(pendingChat: true))
        let page = try rig.newTab("tab_picked")
        await rig.showThenHide("tab_picked", at: 0)

        for seconds in stride(from: 12.0, through: 600, by: 100) { rig.pass(at: seconds) }
        #expect(rig.tabs.existingView("tab_picked") === page, "a New Tab page holding a chip-picked chat was let go")
        #expect(rig.lifecycle.state(of: "tab_picked") != .discarded)
        #expect(rig.released == 0)
    }

    /// A connected chat that does not answer its hide read in time (busy with its turn, an attachment still
    /// encoding) is asked again while it runs, and goes once it answers: one timeout is no lasting draft.
    @Test func aConnectedChatThatDoesNotAnswerItsHideReadIsAskedAgainAndGoesOnceItAnswers() async throws {
        let rig = Rig()
        let page = try rig.chat("tab_slow", session: "s-slow")
        _ = await page.model.respond(to: AgentPaneRequest(body: ["method": "ready", "params": ["reconnect": true]]))
        try #require(page.model.hasHandshake, "the reconnect handshake did not run")
        let left = AgentPaneWakeState(shell: true, shellText: "cargo test")
        let reads = ReadCount()
        // The first read and its retries time out; the page answers the next one.
        let unanswered = 1 + AgentPageHibernation.hideReadRetries
        rig.hibernation.wakeState = { _ in
            reads.count += 1
            return reads.count > unanswered ? left : nil
        }
        rig.advance(to: 0)
        rig.lifecycle.tabDidShow("tab_slow")
        rig.lifecycle.tabDidHide("tab_slow")
        await rig.settle { reads.count == unanswered && rig.hibernation.hideReads["tab_slow"]?.isDone == true }
        #expect(reads.count == unanswered, "an unanswered hide read was not asked again at once")
        #expect(rig.hibernation.hideReads["tab_slow"]?.wake == nil)

        // Unanswered: the page may hold chips, so it stays.
        rig.pass(at: 12)
        rig.pass(at: 305)
        #expect(rig.tabs.existingView("tab_slow") === page, "a connected chat that never answered was let go")

        // Its turn changes: it is asked again, answers, and goes at the next pass.
        rig.hibernation.refreshTurnReasons()
        await rig.settle { rig.hibernation.hideReads["tab_slow"]?.wake != nil }
        #expect(reads.count == unanswered + 1)
        rig.pass(at: 310)
        #expect(rig.tabs.existingView("tab_slow") == nil, "the chat kept its page after it answered its hide read")
        #expect(rig.tabs.wakeStates["tab_slow"] == left, "the late answer did not reach the rebuilt page")
    }
}

/// How often the rig's page was asked what it holds.
@MainActor private final class ReadCount {
    var count = 0
}

/// A timer the queue arms and parks; nothing fires it.
private nonisolated final class LifecycleRigTimer: MainWakeUpTimer {
    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {}
    func park() {}
}

/// The rig's uptime in ns: the queue reads it from any thread, only the test's main actor moves it.
private nonisolated final class LifecycleRigUptime: Sendable {
    private let value = Atomic<UInt64>(0)

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
}
