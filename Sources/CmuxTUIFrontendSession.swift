import Foundation
import CmuxTerminal
import CmuxTUIClient
import os

enum CmuxTUITerminalTransportEvent: Sendable {
    case input(TerminalManualInput)
    case resize(CmuxTUITerminalGeometry)
}

final class CmuxTUITerminalTransportForwarder: Sendable {
    enum SendResult: Equatable, Sendable {
        case enqueued
        case inactive
        case overflow
    }

    private struct QueuedEvent: Sendable {
        let event: CmuxTUITerminalTransportEvent
        let byteCount: Int
        let epoch: UInt64
    }

    private struct State: Sendable {
        var pendingBytes = 0
        var epoch: UInt64 = 0
        var isActive = true
    }

    static let defaultMaximumEventBytes = 1_048_576
    static let defaultMaximumPendingBytes = 4_194_304
    static let defaultMaximumBufferedEvents = 4_096

    private let state: OSAllocatedUnfairLock<State>
    private let continuation: AsyncStream<QueuedEvent>.Continuation
    private let consumer: Task<Void, Never>
    private let maximumEventBytes: Int
    private let maximumPendingBytes: Int
    private let onFailure: @Sendable () -> Void

    init(
        maximumEventBytes: Int = defaultMaximumEventBytes,
        maximumPendingBytes: Int = defaultMaximumPendingBytes,
        maximumBufferedEvents: Int = defaultMaximumBufferedEvents,
        deliver: @escaping @Sendable (CmuxTUITerminalTransportEvent) async -> Bool,
        onFailure: @escaping @Sendable () -> Void
    ) {
        let maximumPendingBytes = max(1, maximumPendingBytes)
        let state = OSAllocatedUnfairLock(initialState: State())
        let (stream, continuation) = AsyncStream.makeStream(
            of: QueuedEvent.self,
            bufferingPolicy: .bufferingOldest(max(1, maximumBufferedEvents))
        )
        self.state = state
        self.continuation = continuation
        self.maximumEventBytes = max(1, min(maximumEventBytes, maximumPendingBytes))
        self.maximumPendingBytes = maximumPendingBytes
        self.onFailure = onFailure
        self.consumer = Task {
            for await queued in stream {
                let shouldDeliver = state.withLock { state in
                    state.isActive && queued.epoch == state.epoch
                }
                guard shouldDeliver, !Task.isCancelled else { continue }
                let accepted = await deliver(queued.event)
                let shouldNotify = state.withLock { state in
                    guard queued.epoch == state.epoch else { return false }
                    state.pendingBytes = max(0, state.pendingBytes - queued.byteCount)
                    guard state.isActive, !accepted else { return false }
                    state.isActive = false
                    state.epoch &+= 1
                    state.pendingBytes = 0
                    return true
                }
                if shouldNotify { onFailure() }
            }
        }
    }

    deinit {
        continuation.finish()
        consumer.cancel()
    }

    @discardableResult
    func send(_ event: CmuxTUITerminalTransportEvent) -> SendResult {
        let byteCount = Self.byteCount(of: event)
        let reservation = state.withLock { state -> (epoch: UInt64?, didOverflow: Bool) in
            guard state.isActive else { return (nil, false) }
            guard byteCount <= maximumEventBytes,
                  byteCount <= maximumPendingBytes - state.pendingBytes else {
                state.isActive = false
                state.epoch &+= 1
                state.pendingBytes = 0
                return (nil, true)
            }
            state.pendingBytes += byteCount
            return (state.epoch, false)
        }
        if reservation.didOverflow {
            onFailure()
            return .overflow
        }
        guard let epoch = reservation.epoch else { return .inactive }

        let queued = QueuedEvent(event: event, byteCount: byteCount, epoch: epoch)
        switch continuation.yield(queued) {
        case .enqueued:
            return .enqueued
        case .dropped, .terminated:
            let shouldNotify = failClosed()
            if shouldNotify { onFailure() }
            return .overflow
        @unknown default:
            let shouldNotify = failClosed()
            if shouldNotify { onFailure() }
            return .overflow
        }
    }

    func shutdown() {
        _ = failClosed()
        continuation.finish()
        consumer.cancel()
    }

    private func failClosed() -> Bool {
        state.withLock { state in
            guard state.isActive else { return false }
            state.isActive = false
            state.epoch &+= 1
            state.pendingBytes = 0
            return true
        }
    }

    private static func byteCount(of event: CmuxTUITerminalTransportEvent) -> Int {
        switch event {
        case .input(.bytes(let data)):
            return max(1, data.count)
        case .input(.namedKey(let name)):
            return max(1, name.utf8.count)
        case .resize:
            return 1
        }
    }
}

@MainActor
final class CmuxTUITerminalBinding {
    private enum ErrorKind: Int, Equatable {
        case renderer
        case runtime
        case transport
    }

    let id: UUID
    let publicTerminalID: String
    private let terminal: CmuxTUITerminal
    private let transportForwarder: CmuxTUITerminalTransportForwarder
    private let transportFailureStream: AsyncStream<Void>
    private let transportFailureContinuation: AsyncStream<Void>.Continuation
    let inputHandler: @Sendable (TerminalManualInput) -> Void
    private weak var surface: TerminalSurface?
    private var transportFailureTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var runtimeCreationFailureObserver: NSObjectProtocol?
    private var previousRuntimeReadyHandler: (@MainActor () -> Void)?
    private var isWaitingForResetRuntime = false
    private var didStart = false
    private var isShuttingDown = false
    private var errorKind: ErrorKind?
    private(set) var errorMessage: String?
    private(set) var diagnostics = ""
    private(set) var didExit = false
    var onShutdown: (@MainActor (UUID) -> Void)?

    init(id: UUID = UUID(), publicTerminalID: String, terminal: CmuxTUITerminal) {
        self.id = id
        self.publicTerminalID = publicTerminalID
        self.terminal = terminal
        let failures = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        transportFailureStream = failures.stream
        let failureContinuation = failures.continuation
        transportFailureContinuation = failureContinuation
        let forwarder = CmuxTUITerminalTransportForwarder(
            deliver: { event in
                switch event {
                case .input(.bytes(let data)):
                    return await terminal.send(data)
                case .input(.namedKey(let name)):
                    return await terminal.sendKey(name)
                case .resize(let geometry):
                    return await terminal.resize(geometry)
                }
            },
            onFailure: {
                failureContinuation.yield()
            }
        )
        transportForwarder = forwarder
        inputHandler = { input in
            _ = forwarder.send(.input(input))
        }
    }

    var resizeHandler: @MainActor @Sendable (Int, Int) -> Void {
        { [weak self] columns, rows in
            guard let self else { return }
            transportForwarder.send(
                .resize(CmuxTUITerminalGeometry(
                    columns: UInt16(clamping: columns),
                    rows: UInt16(clamping: rows)
                ))
            )
        }
    }

    func bind(to surface: TerminalSurface) {
        guard !didStart, !isShuttingDown else { return }
        didStart = true
        self.surface = surface
        let previousRuntimeReadyHandler = surface.onRuntimeReady
        self.previousRuntimeReadyHandler = previousRuntimeReadyHandler
        surface.onRuntimeReady = { [weak self] in
            previousRuntimeReadyHandler?()
            Task { @MainActor [weak self] in
                self?.clearError(kind: .runtime)
                await self?.consumeUpdates()
            }
        }
        runtimeCreationFailureObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceRuntimeCreationFailed,
            object: surface,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runtimeCreationDidFail()
            }
        }
        beginTransportFailureObservation()
        beginUpdates()
    }

    private func runtimeCreationDidFail() {
        guard !isShuttingDown, isWaitingForResetRuntime else { return }
        isWaitingForResetRuntime = false
        recordError(
            kind: .runtime,
            message: String(
                localized: "cmuxTUI.terminal.rendererStartFailed",
                defaultValue: "The native terminal renderer could not start."
            )
        )
        Task { @MainActor [weak self] in
            await self?.consumeUpdates()
        }
    }

    private func beginTransportFailureObservation() {
        let stream = transportFailureStream
        transportFailureTask = Task { [weak self] in
            for await _ in stream {
                guard let self, !isShuttingDown, !Task.isCancelled else { return }
                recordError(
                    kind: .transport,
                    message: String(
                        localized: "cmuxTUI.terminal.transportRejected",
                        defaultValue: "The cmux-tui terminal rejected an update."
                    )
                )
            }
        }
    }

    private func beginUpdates() {
        let terminal = terminal
        updateTask = Task { [weak self] in
            let updates = await terminal.updates()
            await self?.consumeUpdates()
            for await _ in updates.stream {
                guard !Task.isCancelled else { break }
                await self?.consumeUpdates()
            }
            await terminal.stopUpdates(generation: updates.generation)
        }
    }

    private func consumeUpdates() async {
        guard !isShuttingDown, let surface else { return }
        if isWaitingForResetRuntime {
            guard surface.hasLiveSurface else { return }
            isWaitingForResetRuntime = false
        }
        do {
            var hasMore = true
            while hasMore {
                guard !Task.isCancelled, !isShuttingDown else { return }
                let batch = try await terminal.drainRenderEventBatch()
                for event in batch.events {
                    switch event.kind {
                    case .reset:
                        guard surface.resetRemoteOutput(
                            columns: event.geometry.columns,
                            rows: event.geometry.rows,
                            replay: event.payload
                        ) else {
                            throw CmuxTUIClientError.invalidRenderEvent(
                                "remote terminal snapshot could not reset the native surface"
                            )
                        }
                        if !surface.hasLiveSurface {
                            isWaitingForResetRuntime = true
                        }
                    case .bytes:
                        guard surface.processRemoteOutput(event.payload) else {
                            throw CmuxTUIClientError.invalidRenderEvent(
                                "remote terminal output exceeded the pending native surface limit"
                            )
                        }
                    case .resize:
                        guard surface.applyRemoteGrid(
                            columns: event.geometry.columns,
                            rows: event.geometry.rows
                        ) else {
                            throw CmuxTUIClientError.invalidRenderEvent(
                                "remote terminal resize exceeded the pending native surface limit"
                            )
                        }
                    case .ready:
                        surface.forceRefresh(reason: "cmuxTUI.ready")
                    case .exit:
                        didExit = true
                    }
                }
                if isWaitingForResetRuntime { return }
                hasMore = batch.hasMore
                if hasMore { await Task.yield() }
            }
            let snapshot = await terminal.snapshot()
            diagnostics = snapshot.diagnostics
            didExit = didExit || snapshot.didExit
            clearError(kind: .renderer)
        } catch {
            recordError(kind: .renderer, message: error.localizedDescription)
        }
    }

    private func recordError(kind: ErrorKind, message: String) {
        if let errorKind, errorKind.rawValue > kind.rawValue { return }
        errorKind = kind
        errorMessage = message
    }

    private func clearError(kind: ErrorKind) {
        guard errorKind == kind else { return }
        errorKind = nil
        errorMessage = nil
    }

    func shutdown() {
        Task { await shutdownAndWait() }
    }

    func shutdownAndWait() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        transportFailureTask?.cancel()
        updateTask?.cancel()
        if let runtimeCreationFailureObserver {
            NotificationCenter.default.removeObserver(runtimeCreationFailureObserver)
            self.runtimeCreationFailureObserver = nil
        }
        transportForwarder.shutdown()
        transportFailureContinuation.finish()
        if let surface {
            surface.onRuntimeReady = previousRuntimeReadyHandler
        }
        previousRuntimeReadyHandler = nil
        await terminal.shutdown()
        onShutdown?(id)
        onShutdown = nil
    }
}

@MainActor
final class CmuxTUIFrontendSession {
    let id: UUID
    let client: CmuxTUIFrontendClient
    private(set) var bindings: [UUID: CmuxTUITerminalBinding] = [:]
    private var isShuttingDown = false

    private init(id: UUID = UUID(), client: CmuxTUIFrontendClient) {
        self.id = id
        self.client = client
    }

    static func connect(invitation: String) async throws -> CmuxTUIFrontendSession {
        let client = try await CmuxTUIFrontendClient.connect(invitation: invitation)
        return CmuxTUIFrontendSession(client: client)
    }

    func attachTerminal(publicID: String) async throws -> CmuxTUITerminalBinding {
        guard !isShuttingDown else {
            throw CmuxTUIClientError.message("cmux-tui frontend session closed")
        }
        let terminal = try await client.attachTerminal(publicID: publicID)
        let binding = CmuxTUITerminalBinding(
            publicTerminalID: publicID,
            terminal: terminal
        )
        binding.onShutdown = { [weak self] bindingID in
            self?.bindings.removeValue(forKey: bindingID)
        }
        bindings[binding.id] = binding
        return binding
    }

    func shutdown() {
        Task { await shutdownAndWait() }
    }

    func shutdownAndWait() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        let ownedBindings = Array(bindings.values)
        bindings.removeAll()
        for binding in ownedBindings {
            await binding.shutdownAndWait()
        }
        await client.shutdown()
    }
}

struct CmuxTUIAttachResult: Sendable {
    let sessionID: UUID
    let workspaceID: UUID
    let panelID: UUID
}

extension TabManager {
    func attachCmuxTUITerminal(
        invitation: String?,
        sessionID: UUID?,
        publicTerminalID: String,
        title: String,
        focus: Bool
    ) async throws -> CmuxTUIAttachResult {
        let session: CmuxTUIFrontendSession
        let createdSession: Bool
        if let sessionID {
            guard let existing = cmuxTUIFrontendSessions[sessionID] else {
                throw CmuxTUIClientError.message("cmux-tui frontend session not found")
            }
            session = existing
            createdSession = false
        } else {
            guard let invitation, !invitation.isEmpty else {
                throw CmuxTUIClientError.message("invitation is required for a new cmux-tui session")
            }
            session = try await CmuxTUIFrontendSession.connect(invitation: invitation)
            cmuxTUIFrontendSessions[session.id] = session
            createdSession = true
        }

        do {
            let binding = try await session.attachTerminal(publicID: publicTerminalID)
            let workspace = addWorkspace(
                title: title,
                titleSource: .auto,
                initialSurface: .deferred,
                inheritWorkingDirectory: false,
                select: focus,
                autoWelcomeIfNeeded: false,
                autoRefreshMetadata: false
            )
            guard let panel = workspace.addManualMirrorTerminalPanel(
                id: binding.id,
                title: title,
                context: GHOSTTY_SURFACE_CONTEXT_TAB,
                focus: focus,
                publishOrigin: "cmux_tui_attach",
                onInput: binding.inputHandler,
                onResize: binding.resizeHandler
            ) else {
                await binding.shutdownAndWait()
                closeWorkspace(workspace, recordHistory: false)
                throw CmuxTUIClientError.message("failed to create native cmux-tui terminal surface")
            }
            panel.cmuxTUIBinding = binding
            binding.bind(to: panel.surface)
            return CmuxTUIAttachResult(
                sessionID: session.id,
                workspaceID: workspace.id,
                panelID: panel.id
            )
        } catch {
            if createdSession {
                cmuxTUIFrontendSessions.removeValue(forKey: session.id)
                await session.shutdownAndWait()
            }
            throw error
        }
    }
}
