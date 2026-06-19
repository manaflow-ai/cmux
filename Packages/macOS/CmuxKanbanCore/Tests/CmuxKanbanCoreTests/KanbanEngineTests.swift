import Foundation
import Testing

@testable import CmuxKanbanCore

@Suite(.serialized)
struct KanbanEngineTests {
    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTempBaseDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KanbanEngineTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// Builds an engine over a temp repository, optionally seeding a board.
    private func makeEngine(
        seeding board: KanbanBoard? = nil,
        backend: any DispatchBackend,
        liveBackend: (any DispatchBackend)? = nil
    ) async throws -> (engine: KanbanEngine, repository: KanbanBoardRepository, base: URL, workspaceId: UUID) {
        let base = makeTempBaseDirectory()
        let repository = KanbanBoardRepository(baseDirectory: base)
        let workspaceId = board?.workspaceId ?? UUID()
        if let board { try await repository.save(board) }
        let engine = KanbanEngine(
            workspaceId: workspaceId,
            repository: repository,
            backend: backend,
            liveBackend: liveBackend,
            clock: { Self.fixedNow }
        )
        try await engine.start()
        return (engine, repository, base, workspaceId)
    }

    /// Consumes the engine's board stream until `cardId` reaches `column`,
    /// returning that snapshot. Deterministic — no polling or sleeping.
    private func awaitColumn(
        _ engine: KanbanEngine,
        cardId: UUID,
        is column: KanbanColumn
    ) async -> KanbanBoard {
        for await board in engine.boardUpdates {
            if board.card(id: cardId)?.column == column { return board }
        }
        return await engine.currentBoard()
    }

    @Test
    func createTaskAppendsCardToBacklog() async throws {
        let backend = ScriptedDispatchBackend(script: [])
        let (engine, _, base, _) = try await makeEngine(backend: backend)
        defer { try? FileManager.default.removeItem(at: base) }

        let board = await engine.createTask(title: "Write docs", detail: "for the API")

        #expect(board.cards.count == 1)
        #expect(board.cards[0].title == "Write docs")
        #expect(board.cards[0].column == .backlog)
    }

    @Test
    func dispatchRunsCardThroughToDoneAndLogsOutput() async throws {
        let backend = ScriptedDispatchBackend(script: [
            .started(sessionId: "sess-1"),
            .output("building…\n"),
            .exited(status: 0),
        ])
        let (engine, repository, base, _) = try await makeEngine(backend: backend)
        defer { try? FileManager.default.removeItem(at: base) }

        let created = await engine.createTask(title: "Task")
        let cardId = created.cards[0].id

        try await engine.dispatch(cardId: cardId)
        let board = await awaitColumn(engine, cardId: cardId, is: .done)

        let card = try #require(board.card(id: cardId))
        #expect(card.column == .done)
        #expect(card.lastExitStatus == 0)
        #expect(card.sessionId == nil)

        let log = try String(contentsOf: await repository.logURL(cardId: cardId), encoding: .utf8)
        #expect(log == "building…\n")
    }

    @Test
    func dispatchWithNonZeroExitMovesCardToFailed() async throws {
        let backend = ScriptedDispatchBackend(script: [
            .started(sessionId: "s"),
            .exited(status: 2),
        ])
        let (engine, _, base, _) = try await makeEngine(backend: backend)
        defer { try? FileManager.default.removeItem(at: base) }

        let created = await engine.createTask(title: "Task")
        let cardId = created.cards[0].id

        try await engine.dispatch(cardId: cardId)
        let board = await awaitColumn(engine, cardId: cardId, is: .failed)

        let card = try #require(board.card(id: cardId))
        #expect(card.column == .failed)
        #expect(card.lastExitStatus == 2)
    }

    @Test
    func dispatchFailureEventMovesCardToFailed() async throws {
        let backend = ScriptedDispatchBackend(script: [
            .started(sessionId: "s"),
            .failed(message: "spawn error"),
        ])
        let (engine, _, base, _) = try await makeEngine(backend: backend)
        defer { try? FileManager.default.removeItem(at: base) }

        let created = await engine.createTask(title: "Task")
        let cardId = created.cards[0].id

        try await engine.dispatch(cardId: cardId)
        let board = await awaitColumn(engine, cardId: cardId, is: .failed)

        #expect(board.card(id: cardId)?.column == .failed)
    }

    @Test
    func turnCompleteMovesToTestingWhenTestCommandIsSet() async throws {
        let workspaceId = UUID()
        let seed = KanbanBoard(workspaceId: workspaceId, testCommand: "bun test", updatedAt: Self.fixedNow)
        let backend = ScriptedDispatchBackend(
            script: [.started(sessionId: "s"), .turnComplete],
            finishes: false
        )
        let (engine, _, base, _) = try await makeEngine(seeding: seed, backend: backend)
        defer { try? FileManager.default.removeItem(at: base) }

        let created = await engine.createTask(title: "Task")
        let cardId = created.cards[0].id

        try await engine.dispatch(cardId: cardId)
        let board = await awaitColumn(engine, cardId: cardId, is: .testing)

        #expect(board.card(id: cardId)?.column == .testing)
    }

    @Test
    func dispatchBeyondWipLimitIsRejected() async throws {
        let workspaceId = UUID()
        let seed = KanbanBoard(workspaceId: workspaceId, wipLimit: 1, updatedAt: Self.fixedNow)
        let backend = ScriptedDispatchBackend(script: [.started(sessionId: "s")], finishes: false)
        let (engine, _, base, _) = try await makeEngine(seeding: seed, backend: backend)
        defer { try? FileManager.default.removeItem(at: base) }

        await engine.createTask(title: "A")
        let board = await engine.createTask(title: "B")
        let first = board.cards[0].id
        let second = board.cards[1].id

        try await engine.dispatch(cardId: first)
        await #expect(throws: KanbanEngineError.wipLimitReached(limit: 1)) {
            try await engine.dispatch(cardId: second)
        }
    }

    @Test
    func dispatchUnknownCardThrows() async throws {
        let backend = ScriptedDispatchBackend(script: [])
        let (engine, _, base, _) = try await makeEngine(backend: backend)
        defer { try? FileManager.default.removeItem(at: base) }

        let ghost = UUID()
        await #expect(throws: KanbanEngineError.unknownCard(ghost)) {
            try await engine.dispatch(cardId: ghost)
        }
    }

    @Test
    func cancelRequeuesRunningCardToReady() async throws {
        let backend = ScriptedDispatchBackend(script: [.started(sessionId: "s")], finishes: false)
        let (engine, _, base, _) = try await makeEngine(backend: backend)
        defer { try? FileManager.default.removeItem(at: base) }

        let created = await engine.createTask(title: "Task")
        let cardId = created.cards[0].id

        try await engine.dispatch(cardId: cardId)
        await engine.cancel(cardId: cardId)

        let board = await engine.currentBoard()
        #expect(board.card(id: cardId)?.column == .ready)
        #expect(board.card(id: cardId)?.sessionId == nil)
        let cancelled = await backend.cancelledCount()
        #expect(cancelled == 1)
    }

    @Test
    func dispatchLiveRoutesRunAndCancelToTheLiveBackend() async throws {
        let headless = ScriptedDispatchBackend(script: [.started(sessionId: "h")], finishes: false)
        let live = ScriptedDispatchBackend(script: [.started(sessionId: "l")], finishes: false)
        let (engine, _, base, _) = try await makeEngine(backend: headless, liveBackend: live)
        defer { try? FileManager.default.removeItem(at: base) }

        let created = await engine.createTask(title: "Task")
        let cardId = created.cards[0].id

        try await engine.dispatchLive(cardId: cardId)
        await engine.cancel(cardId: cardId)

        let liveCancelled = await live.cancelledCount()
        let headlessCancelled = await headless.cancelledCount()
        // A live-dispatched card must be cancelled through the live backend that
        // started it — never the headless one.
        #expect(liveCancelled == 1)
        #expect(headlessCancelled == 0)
    }

    @Test
    func dispatchRoutesRunAndCancelToTheHeadlessBackend() async throws {
        let headless = ScriptedDispatchBackend(script: [.started(sessionId: "h")], finishes: false)
        let live = ScriptedDispatchBackend(script: [.started(sessionId: "l")], finishes: false)
        let (engine, _, base, _) = try await makeEngine(backend: headless, liveBackend: live)
        defer { try? FileManager.default.removeItem(at: base) }

        let created = await engine.createTask(title: "Task")
        let cardId = created.cards[0].id

        try await engine.dispatch(cardId: cardId)
        await engine.cancel(cardId: cardId)

        let headlessCancelled = await headless.cancelledCount()
        let liveCancelled = await live.cancelledCount()
        #expect(headlessCancelled == 1)
        #expect(liveCancelled == 0)
    }

    @Test
    func concurrentCreateTasksAllPersistWithoutLoss() async throws {
        let backend = ScriptedDispatchBackend(script: [])
        let (engine, _, base, _) = try await makeEngine(backend: backend)
        defer { try? FileManager.default.removeItem(at: base) }

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 25 {
                group.addTask {
                    await engine.createTask(title: "Task \(index)")
                }
            }
        }

        let board = await engine.currentBoard()
        #expect(board.cards.count == 25)
    }
}
