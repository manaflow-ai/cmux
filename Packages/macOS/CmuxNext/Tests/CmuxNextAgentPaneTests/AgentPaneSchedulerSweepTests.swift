import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The agent pane's main-thread work on the app's scheduler (p06-scheduler-330, rule 9): each owner the sweep moved
/// lands as a task of its class, named in the scheduler's owners ledger, and a hidden chat holds its stream until its
/// tab node shows. Before the sweep, each of these was an unattributed main-queue job (`Task { @MainActor in }`),
/// which the ledger has no row for, and the pacer read AppKit's view tree on every delivery.
@Suite(.serialized)
@MainActor
struct AgentPaneSchedulerSweepTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A scheduler whose board keeps an owners ledger the test reads.
    private final class Rig {
        let board = MainTaskBoard(ledger: MainOwnerLedger(capacity: 64, folding: .manual))
        lazy var work = MainWorkScheduler(budget: MainFrameBudget(board: board))

        func row(_ owner: String) -> MainOwnerLedger.Owner? {
            board.ownerSnapshot().owners.first { $0.owner == owner }
        }
    }

    /// What a callback saw, on the main actor.
    private final class Seen {
        var values: [String] = []
        var pages: [JSONValue] = []
        var calls = 0
    }

    /// Main run loop passes, where the scheduler's turns and off-main posts arrive, until `done` or 5 s.
    private static func settle(until done: () -> Bool) async {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !done(), ContinuousClock.now < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
            await Task.yield()
        }
    }

    // MARK: AgentPageProvider.replay (visible)

    /// A new subscriber's catch-up reaches its page after `subscribe` returned, as visible tasks of the provider.
    @Test func aSubscribersCatchUpLandsAsVisibleTasksAfterTheSubscription() async throws {
        let rig = Rig(), seen = Seen()
        let provider = AgentPageProvider(mainWork: rig.work) { _ in nil }
        provider.publish(.command("before-subscribe"))
        let subscription = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null,
                                                        context: PageCallContext(page: PageDescriptor.agent.id)) { seen.pages.append($0) }
        defer { subscription.cancel() }
        #expect(seen.pages.isEmpty, "the catch-up ran inside subscribe, before the page had its subscription")
        await Self.settle { !seen.pages.isEmpty }
        #expect(seen.pages.count == 1)
        let row = try #require(rig.row("AgentPageProvider.replay"), "the catch-up ran outside the scheduler: no owner row")
        #expect(row.workClass == .visible)
    }

    // MARK: AgentPaneModel.sessionHarness (visible)

    /// A harness the socket's queue reads lands as one visible task, and only for the pane's own session.
    @Test func aSessionsHarnessLandsAsAVisibleTaskOnlyForThePanesSession() async throws {
        let rig = Rig(), seen = Seen()
        let model = AgentPaneModel(host: NoHost(), sessionId: "s1")
        model.followSessionHarness(on: rig.work) { seen.values.append($0) }
        let sessions = model.transport.sessions
        await withCheckedContinuation { (read: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                for id in ["other", "s1"] {
                    sessions.observeFolder(["result": ["session": ["sessionId": id, "harness": "claude"]]], replyTo: "_acpmux/attach")
                }
                read.resume()
            }
        }
        await Self.settle { !seen.values.isEmpty && rig.row("AgentPaneModel.sessionHarness")?.tasks == 2 }
        #expect(seen.values == ["s1"], "another session's harness reached the pane's tab")
        let row = try #require(rig.row("AgentPaneModel.sessionHarness"), "the report hopped outside the scheduler")
        #expect(row.workClass == .visible)
    }

    // MARK: AcpmuxMailboxSubscription (the owner's class)

    /// Each page the reader reads off main lands as one task of the owner's class.
    @Test func aMailboxPageLandsAsOneTaskOfTheOwnersClass() async throws {
        let rig = Rig(), seen = Seen()
        let reader = AcpmuxMailboxReader(socketPath: "/nonexistent/acpmux.sock", wake: RetryWake(owner: "AgentPaneSchedulerSweepTests"),
                                         clock: ContinuousClock(), policy: .firstConnect) { after in
            guard after == 0 else { try await Task.sleep(for: .seconds(60)); throw CancellationError() }
            return AcpmuxMailboxPage(messages: [], nextCursor: 1)
        }
        let subscription = AcpmuxMailboxSubscription(mainWork: rig.work, workClass: .automation, owner: "test.reports")
        let run = subscription.start(reader) { page in seen.values.append("\(page.nextCursor ?? 0)") }
        await Self.settle { !seen.values.isEmpty }
        subscription.stop()
        await run.value
        #expect(seen.values == ["1"])
        let row = try #require(rig.row("test.reports"), "the page hopped outside the scheduler")
        #expect(row.workClass == .automation)
    }

    // MARK: AgentPaneFramePacer (its tab node)

    /// A pane that follows its tab node holds its stream while the node is hidden, whatever the view tree says, and
    /// delivers it in the node's show flip; a visible node delivers at once.
    @Test func aHiddenTabNodeHoldsTheStreamUntilItShows() {
        let root = VisibilityNode(root: "app", own: .visible)
        let tab = VisibilityNode("tab", own: .hidden, parent: root)
        let seen = Seen()
        // The view tree would say shown (isHidden false): only the node holds the stream.
        let pacer = AgentPaneFramePacer(frames: AgentPaneHiddenPacingTests.Ticks(), fallback: AgentPaneHiddenPacingTests.Deadline(),
                                        nextTurn: { _ in }, isHidden: { false })
        pacer.follow(tab)
        pacer.schedule {
            seen.calls += 1
            return AgentPaneFlush(delivered: true, more: false)
        }
        #expect(seen.calls == 0, "a hidden tab's chat got its stream")
        tab.set(.visible)
        #expect(seen.calls == 1, "showing the tab did not deliver what it held")
        pacer.delivered()
        pacer.stop()
    }
}
