public import Foundation

/// The single source of truth for one workspace's Kanban board at runtime.
///
/// `KanbanEngine` is an `actor`, so every board mutation — `createTask`,
/// `moveCard`, `dispatch`, and every backend progress event — is serialized
/// through actor isolation. That removes the read-modify-write race the manual
/// coordinator had (two concurrent mutations both reading the cached board and
/// the last writer clobbering the other): each mutation reads the latest board
/// and reassigns it before any `await`, so no update is lost.
///
/// The engine owns *dispatch policy*: a ``DispatchBackend`` reports raw
/// lifecycle facts (``KanbanDispatchProgress``) and the engine maps them onto
/// column transitions (`building → testing → done`, or `→ failed`). It publishes
/// two streams: ``boardUpdates`` (a snapshot after every mutation) and
/// ``progressEvents`` (per-card lifecycle events for live UI). The webview
/// coordinator subscribes and projects them; it never mutates the board itself.
public actor KanbanEngine {
    private let workspaceId: UUID
    private let repository: KanbanBoardRepository
    private let backend: any DispatchBackend
    private let liveBackend: any DispatchBackend
    private let clock: @Sendable () -> Date

    private var board: KanbanBoard
    /// Consumer task per running card; cancelled on ``cancel(cardId:)``.
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    /// Live dispatch handle per running card, paired with the backend that
    /// started the run so ``cancel(cardId:)`` routes back to the right one
    /// (headless vs live).
    private var handles: [UUID: (handle: KanbanDispatchHandle, backend: any DispatchBackend)] = [:]

    /// A board snapshot emitted after every mutation. The latest value is the
    /// authoritative board; subscribers reconcile from it.
    public nonisolated let boardUpdates: AsyncStream<KanbanBoard>
    private nonisolated let boardContinuation: AsyncStream<KanbanBoard>.Continuation

    /// Per-card lifecycle events (started/output/exited…), for live UI.
    public nonisolated let progressEvents: AsyncStream<KanbanCardProgress>
    private nonisolated let progressContinuation: AsyncStream<KanbanCardProgress>.Continuation

    /// Creates an engine for `workspaceId`.
    ///
    /// - Parameters:
    ///   - workspaceId: The workspace whose board this engine owns.
    ///   - repository: Persistence for the board JSON and per-card logs.
    ///   - backend: The dispatch backend that actually runs cards (headless).
    ///   - liveBackend: The backend for ``dispatchLive(cardId:)`` — an
    ///     interactive, visible agent session. Defaults to `backend` when
    ///     omitted, so the headless dispatch contract is unchanged.
    ///   - clock: Injected time source; tests pass a deterministic clock.
    public init(
        workspaceId: UUID,
        repository: KanbanBoardRepository,
        backend: any DispatchBackend,
        liveBackend: (any DispatchBackend)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.workspaceId = workspaceId
        self.repository = repository
        self.backend = backend
        self.liveBackend = liveBackend ?? backend
        self.clock = clock
        self.board = .empty(workspaceId: workspaceId, now: clock())

        var boardCont: AsyncStream<KanbanBoard>.Continuation!
        self.boardUpdates = AsyncStream { boardCont = $0 }
        self.boardContinuation = boardCont

        var progressCont: AsyncStream<KanbanCardProgress>.Continuation!
        self.progressEvents = AsyncStream { progressCont = $0 }
        self.progressContinuation = progressCont
    }

    /// Loads the persisted board, reconciles cards orphaned by a relaunch, and
    /// emits the result. Call once before the first mutation.
    @discardableResult
    public func start() async throws -> KanbanBoard {
        let loaded = try await repository.load(workspaceId: workspaceId, now: clock())
        let reconciled = loaded.reconcilingOrphansAfterRelaunch(now: clock())
        await commit(reconciled)
        return board
    }

    /// The current in-memory board (authoritative between disk writes).
    public func currentBoard() -> KanbanBoard {
        board
    }

    /// Appends a new card in `backlog` and returns the updated board.
    @discardableResult
    public func createTask(
        title: String,
        detail: String = "",
        backendKind: KanbanBackendKind = .cmux,
        agentProvider: String? = nil
    ) async -> KanbanBoard {
        let now = clock()
        let card = KanbanCard(
            title: title,
            detail: detail,
            column: .backlog,
            backendKind: backendKind,
            agentProvider: agentProvider,
            createdAt: now,
            updatedAt: now
        )
        await commit(board.upserting(card, now: now))
        return board
    }

    /// Moves a card to `column` and returns the updated board.
    @discardableResult
    public func moveCard(id: UUID, to column: KanbanColumn) async -> KanbanBoard {
        await commit(board.movingCard(id: id, to: column, now: clock()))
        return board
    }

    /// Starts running the card, moving it to `building` and streaming its
    /// progress onto the board.
    ///
    /// - Throws: ``KanbanEngineError/unknownCard(_:)`` if the card is absent, or
    ///   ``KanbanEngineError/wipLimitReached(limit:)`` if the board is full.
    public func dispatch(cardId: UUID) async throws {
        try await dispatch(cardId: cardId, using: backend)
    }

    /// Like ``dispatch(cardId:)`` but routes the run to the *live* backend — an
    /// interactive, visible agent session rather than a headless process. Column
    /// policy is identical; only the backend that owns the run differs, so
    /// ``cancel(cardId:)`` is routed back to whichever backend started it.
    public func dispatchLive(cardId: UUID) async throws {
        try await dispatch(cardId: cardId, using: liveBackend)
    }

    private func dispatch(cardId: UUID, using backend: any DispatchBackend) async throws {
        guard let card = board.card(id: cardId) else {
            throw KanbanEngineError.unknownCard(cardId)
        }
        // Already in flight: ignore a duplicate dispatch.
        guard !card.column.occupiesWipSlot else { return }
        guard board.wipInUse < board.wipLimit else {
            throw KanbanEngineError.wipLimitReached(limit: board.wipLimit)
        }

        await commit(board.movingCard(id: cardId, to: .building, now: clock()))
        let dispatched = board.card(id: cardId) ?? card

        let session: KanbanDispatchSession
        do {
            session = try await backend.dispatch(card: dispatched, workingDirectory: dispatched.worktreePath)
        } catch {
            await fail(cardId: cardId, message: "Failed to start: \(error)")
            return
        }

        handles[cardId] = (session.handle, backend)
        let token = session.handle.token
        let task = Task { [weak self] in
            for await progress in session.progress {
                await self?.handleProgress(progress, cardId: cardId, token: token)
            }
            await self?.finishRunIfStillActive(cardId: cardId, token: token)
        }
        runningTasks[cardId] = task
    }

    /// Cancels a running card, terminating its backend run and re-queueing it to
    /// `ready` so it can be dispatched again. A no-op if the card is not running.
    ///
    /// Cleanup happens *before* any `await`, so progress events still in flight
    /// for this run fail the token guard in ``handleProgress(_:cardId:token:)``
    /// and are discarded — a cancelled card can never be silently resurrected by
    /// a late `started`/`output` event.
    public func cancel(cardId: UUID) async {
        guard let (handle, backend) = handles[cardId] else { return }
        let task = runningTasks[cardId]
        cleanup(cardId)
        task?.cancel()
        if var card = board.card(id: cardId), card.column.occupiesWipSlot {
            card.column = .ready
            card.sessionId = nil
            await commit(board.upserting(card, now: clock()))
        }
        await backend.cancel(handle)
    }

    // MARK: - Progress handling

    /// Applies one progress event, ignoring it unless it belongs to the run that
    /// is still current for this card (`token` matches the live handle). This
    /// drops events from a cancelled or already-finished run, and from a stale
    /// run when a card has been re-dispatched.
    private func handleProgress(_ progress: KanbanDispatchProgress, cardId: UUID, token: UUID) async {
        guard handles[cardId]?.handle.token == token else { return }
        switch progress {
        case .started(let sessionId):
            if var card = board.card(id: cardId) {
                card.sessionId = sessionId
                await commit(board.upserting(card, now: clock()))
            }
        case .provisioned(let worktreePath, let branchName):
            if var card = board.card(id: cardId) {
                card.worktreePath = worktreePath
                card.branchName = branchName
                card.logsRef = "logs/\(cardId.uuidString).log"
                await commit(board.upserting(card, now: clock()))
            }
        case .output(let text):
            try? await repository.appendLog(cardId: cardId, text: text)
        case .turnComplete:
            if board.testCommand != nil,
               let card = board.card(id: cardId),
               card.column == .building {
                await commit(board.movingCard(id: cardId, to: .testing, now: clock()))
            }
        case .exited(let status):
            await finish(cardId: cardId, exitStatus: status)
        case .failed(let message):
            await fail(cardId: cardId, message: message)
        }
        progressContinuation.yield(KanbanCardProgress(cardId: cardId, progress: progress))
    }

    /// Terminal success/failure: a clean exit goes to `done`, otherwise `failed`.
    private func finish(cardId: UUID, exitStatus: Int32) async {
        guard var card = board.card(id: cardId) else { return }
        card.lastExitStatus = exitStatus
        card.sessionId = nil
        card.column = exitStatus == 0 ? .done : .failed
        await commit(board.upserting(card, now: clock()))
        cleanup(cardId)
    }

    /// Marks a card failed, recording `message` in its log first. Every failure
    /// path routes through here — a backend-reported `.failed` event, a start
    /// failure (`backend.dispatch` threw), and a progress stream that ended
    /// without a terminal event — so the reason is always persisted, never just
    /// the backend-reported ones.
    private func fail(cardId: UUID, message: String) async {
        try? await repository.appendLog(cardId: cardId, text: message + "\n")
        guard var card = board.card(id: cardId) else { return }
        card.sessionId = nil
        card.column = .failed
        await commit(board.upserting(card, now: clock()))
        cleanup(cardId)
    }

    /// Called when a progress stream finishes without a terminal event. If the
    /// run is still current and the card is still in flight, treat it as an
    /// unexpected end and fail it.
    private func finishRunIfStillActive(cardId: UUID, token: UUID) async {
        guard handles[cardId]?.handle.token == token else { return }
        if let card = board.card(id: cardId), card.column.occupiesWipSlot {
            await fail(cardId: cardId, message: "Dispatch ended without an exit status.")
        } else {
            cleanup(cardId)
        }
    }

    private func cleanup(_ cardId: UUID) {
        runningTasks[cardId] = nil
        handles[cardId] = nil
    }

    /// Reassigns the board (synchronously, before any `await`), publishes the
    /// snapshot, and persists. The synchronous reassign is what serializes
    /// concurrent mutations.
    private func commit(_ newBoard: KanbanBoard) async {
        board = newBoard
        boardContinuation.yield(newBoard)
        try? await repository.save(newBoard)
    }
}
