import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Close Workspace at the press (`WorkspaceCloseFlow`): Cmd-Shift-W looked like it did nothing
/// because the row moved only after a process-info round trip per terminal (the "still running"
/// question, up to 1 s each), and not at all while the daemon was slow.
@MainActor @Suite(.serialized) struct WorkspaceCloseFlowTests {
    /// What the flow did, in order.
    @MainActor private final class Log {
        var steps: [String] = []
    }

    @MainActor private final class Flag {
        var on = true
    }

    /// Holds the question until the test answers it (a daemon that has not answered process-info).
    @MainActor private final class Pending {
        private var continuation: CheckedContinuation<DestructiveConfirmation.Prompt?, Never>?
        var isAsked: Bool { continuation != nil }

        func question() async -> DestructiveConfirmation.Prompt? {
            await withCheckedContinuation { continuation = $0 }
        }

        func answer(_ prompt: DestructiveConfirmation.Prompt?) {
            continuation?.resume(returning: prompt)
            continuation = nil
        }
    }

    private static let running = DestructiveConfirmation.Prompt(title: "Close “one”?", body: "sleep is still running", button: "Close")

    private func flow(_ id: String, closing: ClosingWorkspaces, log: Log, pending: Pending, closes: Bool = true,
                      exists: @escaping @MainActor () -> Bool = { true }) -> WorkspaceCloseFlow {
        WorkspaceCloseFlow(
            hide: { log.steps.append("hide"); return closing.begin(id, among: [id, "other"]) },
            question: {
                log.steps.append("ask process-info")
                guard await pending.question() != nil else { return nil }
                return {
                    log.steps.append("question")
                    return closes
                }
            },
            exists: exists,
            send: { _ in
                log.steps.append("send")
                return Task { @MainActor in
                    closing.end(id, refused: false, in: nil)
                    return nil
                }
            },
            restore: { hidden in
                log.steps.append("restore")
                if hidden { closing.end(id, refused: false, in: nil) }
            })
    }

    @Test func theRowLeavesBeforeAnyTerminalAnswers() async throws {
        let closing = ClosingWorkspaces(), log = Log(), pending = Pending()
        let work = try #require(flow("one", closing: closing, log: log, pending: pending).start("one", asks: true))
        // In the press's turn: hidden, and nothing waits on the daemon yet.
        #expect(closing.ids == ["one"])
        #expect(log.steps == ["hide"])
        while !pending.isAsked { await Task.yield() }
        // The terminals have not answered: the row stays gone, nothing was sent.
        #expect(closing.ids == ["one"])
        #expect(log.steps == ["hide", "ask process-info"])
        pending.answer(nil)
        #expect(await work.value == nil)
        #expect(log.steps == ["hide", "ask process-info", "send"])
        #expect(closing.ids.isEmpty)
    }

    @Test func cancellingTheQuestionListsTheRowAgainAndSendsNothing() async throws {
        let closing = ClosingWorkspaces(), log = Log(), pending = Pending()
        let work = try #require(flow("one", closing: closing, log: log, pending: pending, closes: false).start("one", asks: true))
        while !pending.isAsked { await Task.yield() }
        pending.answer(Self.running)
        _ = await work.value
        #expect(log.steps == ["hide", "ask process-info", "question", "restore"])
        #expect(closing.ids.isEmpty)
    }

    @Test func closeInTheQuestionSendsIt() async throws {
        let closing = ClosingWorkspaces(), log = Log(), pending = Pending()
        let work = try #require(flow("one", closing: closing, log: log, pending: pending).start("one", asks: true))
        while !pending.isAsked { await Task.yield() }
        pending.answer(Self.running)
        _ = await work.value
        #expect(log.steps == ["hide", "ask process-info", "question", "send"])
    }

    @Test func aSecondPressDuringTheCloseSendsNothing() async throws {
        let closing = ClosingWorkspaces(), log = Log(), pending = Pending()
        let close = flow("one", closing: closing, log: log, pending: pending)
        let work = try #require(close.start("one", asks: true))
        #expect(close.start("one", asks: true) == nil)
        while !pending.isAsked { await Task.yield() }
        pending.answer(nil)
        _ = await work.value
        #expect(log.steps.filter { $0 == "hide" }.count == 1)
        #expect(log.steps.filter { $0 == "send" }.count == 1)
        // Once it ended, a new close of that id may start.
        #expect(!WorkspaceCloseFlow.running.contains("one"))
    }

    @Test func aScriptedConfirmedCloseNeverAsksAndQueuesInThePressTurn() async throws {
        let closing = ClosingWorkspaces(), log = Log(), pending = Pending()
        let work = try #require(flow("one", closing: closing, log: log, pending: pending).start("one", asks: false))
        // Queued before start returns: it keeps its place in the window's lane.
        #expect(log.steps == ["hide", "send"])
        _ = await work.value
        #expect(log.steps == ["hide", "send"])
    }

    @Test func theLateQuestionIsNotConfirmedByReturn() {
        var late = Self.running
        late.returnConfirms = false
        #expect(DestructiveConfirmation.spec(late).defaultButton == nil)
        #expect(DestructiveConfirmation.spec(Self.running).defaultButton?.id == DestructiveConfirmation.confirmID)
    }

    @Test func aWorkspaceClosedElsewhereDuringTheQuestionIsNotSentAgain() async throws {
        let closing = ClosingWorkspaces(), log = Log(), pending = Pending()
        let listed = Flag()
        let work = try #require(flow("one", closing: closing, log: log, pending: pending, exists: { listed.on }).start("one", asks: true))
        while !pending.isAsked { await Task.yield() }
        listed.on = false
        pending.answer(Self.running)
        _ = await work.value
        #expect(log.steps == ["hide", "ask process-info", "restore"])
        #expect(closing.ids.isEmpty)
    }
}
