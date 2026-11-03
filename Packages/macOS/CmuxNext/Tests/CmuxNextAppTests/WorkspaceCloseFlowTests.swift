import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Close Workspace (`WorkspaceCloseFlow`). First Cmd-Shift-W looked like it did nothing because the
/// row moved only after a process-info round trip per terminal; then the row left at the press and
/// the "still running" question came up behind it, so the person watched the row animate away
/// before being asked, and Cancel had to bring it back. Now a close whose store shows a terminal that
/// may run a program keeps its row until the answer. Any other close leaves at the press and still
/// asks its terminals behind it (the store can read a prompt while ssh runs).
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

    /// Holds the person's answer until the test gives it (the question is up).
    @MainActor private final class Gate {
        private var continuation: CheckedContinuation<Bool, Never>?
        var isWaiting: Bool { continuation != nil }

        func wait() async -> Bool { await withCheckedContinuation { continuation = $0 } }

        func open(_ closes: Bool) {
            continuation?.resume(returning: closes)
            continuation = nil
        }
    }

    private static let running = DestructiveConfirmation.Prompt(title: "Close “one”?", body: "sleep is still running", button: "Close")

    private func flow(_ id: String, closing: ClosingWorkspaces, log: Log, pending: Pending, closes: Bool = true, mayAsk: Bool = true,
                      exists: @escaping @MainActor () -> Bool = { true }) -> WorkspaceCloseFlow {
        WorkspaceCloseFlow(
            hide: { log.steps.append("hide"); return closing.begin(id, among: [id, "other"]) },
            mayAsk: { mayAsk },
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

    @Test func theRowStaysWhileTheTerminalsAnswer() async throws {
        let closing = ClosingWorkspaces(), log = Log(), pending = Pending()
        let work = try #require(flow("one", closing: closing, log: log, pending: pending).start("one", asks: true))
        // In the press's turn: nothing hidden, nothing sent.
        #expect(closing.ids.isEmpty)
        #expect(log.steps.isEmpty)
        while !pending.isAsked { await Task.yield() }
        // The terminals have not answered: the row is still listed.
        #expect(closing.ids.isEmpty)
        #expect(log.steps == ["ask process-info"])
        pending.answer(nil)
        #expect(await work.value == nil)
        // Nothing runs: the row leaves, then the close is sent.
        #expect(log.steps == ["ask process-info", "hide", "send"])
        #expect(closing.ids.isEmpty)
    }

    @Test func theRowStaysWhileTheQuestionIsUpAndLeavesOnlyAfterClose() async throws {
        let closing = ClosingWorkspaces(), log = Log(), pending = Pending()
        let gate = Gate()
        let close = WorkspaceCloseFlow(
            hide: { log.steps.append("hide"); return closing.begin("one", among: ["one", "other"]) },
            mayAsk: { true },
            question: {
                log.steps.append("ask process-info")
                guard await pending.question() != nil else { return nil }
                return {
                    log.steps.append("question")
                    return await gate.wait()
                }
            },
            exists: { true },
            send: { _ in log.steps.append("send"); return Task { @MainActor in nil } },
            restore: { _ in log.steps.append("restore") })
        let work = try #require(close.start("one", asks: true))
        while !pending.isAsked { await Task.yield() }
        pending.answer(Self.running)
        while !gate.isWaiting { await Task.yield() }
        // The question is up: the row has not moved.
        #expect(closing.ids.isEmpty)
        #expect(log.steps == ["ask process-info", "question"])
        gate.open(true)
        _ = await work.value
        #expect(log.steps == ["ask process-info", "question", "hide", "send"])
        #expect(closing.ids == ["one"])
    }

    @Test func cancellingTheQuestionNeverHidesTheRowAndSendsNothing() async throws {
        let closing = ClosingWorkspaces(), log = Log(), pending = Pending()
        let work = try #require(flow("one", closing: closing, log: log, pending: pending, closes: false).start("one", asks: true))
        while !pending.isAsked { await Task.yield() }
        pending.answer(Self.running)
        _ = await work.value
        #expect(log.steps == ["ask process-info", "question"])
        #expect(closing.ids.isEmpty)
        #expect(!WorkspaceCloseFlow.running.contains("one"))
    }

    @Test func closeInTheQuestionHidesThenSendsIt() async throws {
        let closing = ClosingWorkspaces(), log = Log(), pending = Pending()
        let work = try #require(flow("one", closing: closing, log: log, pending: pending).start("one", asks: true))
        while !pending.isAsked { await Task.yield() }
        pending.answer(Self.running)
        _ = await work.value
        #expect(log.steps == ["ask process-info", "question", "hide", "send"])
    }

    @Test func aCloseOfIdleShellsLeavesAtThePressAndStillAsksBehindIt() async throws {
        let closing = ClosingWorkspaces(), log = Log(), pending = Pending()
        let work = try #require(flow("one", closing: closing, log: log, pending: pending, mayAsk: false).start("one", asks: true))
        // Shells at their prompt: the row leaves in the press's turn.
        #expect(log.steps == ["hide"])
        #expect(closing.ids == ["one"])
        while !pending.isAsked { await Task.yield() }
        pending.answer(nil)
        _ = await work.value
        #expect(log.steps == ["hide", "ask process-info", "send"])
    }

    @Test func aProgramBehindAPromptStillAsksAndCancelListsTheRowAgain() async throws {
        let closing = ClosingWorkspaces(), log = Log(), pending = Pending()
        let work = try #require(flow("one", closing: closing, log: log, pending: pending, closes: false, mayAsk: false)
            .start("one", asks: true))
        while !pending.isAsked { await Task.yield() }
        // ssh at a remote prompt: the store read a prompt, the daemon reads ssh in the foreground.
        pending.answer(Self.running)
        _ = await work.value
        #expect(log.steps == ["hide", "ask process-info", "question", "restore"])
        #expect(closing.ids.isEmpty)
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
        #expect(log.steps == ["ask process-info"])
        #expect(closing.ids.isEmpty)
    }
}
