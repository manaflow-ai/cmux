import Foundation
import CmuxTerminal
import CmuxTUIClient

private enum CmuxTUITerminalTransportEvent: Sendable {
    case input(TerminalManualInput)
    case resize(CmuxTUITerminalGeometry)
}

@MainActor
final class CmuxTUITerminalBinding {
    let id: UUID
    let publicTerminalID: String
    private let terminal: CmuxTUITerminal
    private let transportStream: AsyncStream<CmuxTUITerminalTransportEvent>
    private let transportContinuation: AsyncStream<CmuxTUITerminalTransportEvent>.Continuation
    let inputHandler: @Sendable (TerminalManualInput) -> Void
    private weak var surface: TerminalSurface?
    private var transportTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var didStart = false
    private var isShuttingDown = false
    private(set) var errorMessage: String?
    private(set) var diagnostics = ""
    private(set) var didExit = false
    var onShutdown: (@MainActor (UUID) -> Void)?

    init(id: UUID = UUID(), publicTerminalID: String, terminal: CmuxTUITerminal) {
        self.id = id
        self.publicTerminalID = publicTerminalID
        self.terminal = terminal
        let transport = AsyncStream<CmuxTUITerminalTransportEvent>.makeStream()
        transportStream = transport.stream
        let continuation = transport.continuation
        transportContinuation = continuation
        inputHandler = { continuation.yield(.input($0)) }
    }

    var resizeHandler: @MainActor @Sendable (Int, Int) -> Void {
        { [weak self] columns, rows in
            guard let self else { return }
            transportContinuation.yield(
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
        beginTransportDelivery()
        beginUpdates()
    }

    private func beginTransportDelivery() {
        let stream = transportStream
        let terminal = terminal
        transportTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                let accepted: Bool
                switch event {
                case .input(.bytes(let data)):
                    accepted = await terminal.send(data)
                case .input(.namedKey(let name)):
                    accepted = await terminal.sendKey(name)
                case .resize(let geometry):
                    accepted = await terminal.resize(geometry)
                }
                guard let self, !isShuttingDown else { return }
                if !accepted {
                    errorMessage = String(
                        localized: "cmuxTUI.terminal.transportRejected",
                        defaultValue: "The cmux-tui terminal rejected an update."
                    )
                }
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
                    case .bytes:
                        surface.processRemoteOutput(event.payload)
                    case .resize:
                        surface.applyRemoteGrid(
                            columns: event.geometry.columns,
                            rows: event.geometry.rows
                        )
                    case .ready:
                        surface.forceRefresh(reason: "cmuxTUI.ready")
                    case .exit:
                        didExit = true
                    }
                }
                hasMore = batch.hasMore
                if hasMore { await Task.yield() }
            }
            let snapshot = await terminal.snapshot()
            diagnostics = snapshot.diagnostics
            didExit = didExit || snapshot.didExit
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func shutdown() {
        Task { await shutdownAndWait() }
    }

    func shutdownAndWait() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        transportTask?.cancel()
        updateTask?.cancel()
        transportContinuation.finish()
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
