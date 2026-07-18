import AppKit
import CmuxWorkspaceShare
import Combine
import Foundation

@MainActor
final class WorkspaceShareHostSession {
    let session: WorkspaceShareSession
    let workspaceID: UUID

    private weak var workspace: Workspace?
    private weak var tabManager: TabManager?
    private let client: WorkspaceShareClient
    private let promptCoordinator: WorkspaceShareAccessPromptCoordinator
    private lazy var cursorOverlay = WorkspaceShareCursorOverlayController(
        window: tabManager?.window,
        onSendChat: { [weak self] text in
            guard let self,
                  let payload = try? WorkspaceShareJSONValue.encode(ChatSendPayload(text: text)) else { return }
            Task { @MainActor in await self.send(type: "chat.message", payload: payload) }
        }
    )
    private let accessTokenProvider: @MainActor @Sendable () async throws -> String
    private let onWorkspaceClosed: @MainActor () -> Void
    private var exporter: WorkspaceShareExporter?
    private var eventTask: Task<Void, Never>?
    private var tabsCancellable: AnyCancellable?
    private var stopping = false

    init(
        session: WorkspaceShareSession,
        workspace: Workspace,
        tabManager: TabManager,
        accessTokenProvider: @escaping @MainActor @Sendable () async throws -> String,
        client: WorkspaceShareClient = WorkspaceShareClient(),
        onWorkspaceClosed: @escaping @MainActor () -> Void
    ) {
        self.session = session
        workspaceID = workspace.id
        self.workspace = workspace
        self.tabManager = tabManager
        self.client = client
        promptCoordinator = WorkspaceShareAccessPromptCoordinator(window: tabManager.window)
        self.accessTokenProvider = accessTokenProvider
        self.onWorkspaceClosed = onWorkspaceClosed
    }

    func start(accessToken: String) async throws {
        stopping = false
        let iterator = try await connect(accessToken: accessToken)
        guard let workspace, let tabManager else { throw WorkspaceShareError.unavailable }
        let exporter = WorkspaceShareExporter(
            workspace: workspace,
            tabManager: tabManager,
            cursorOverlay: cursorOverlay
        ) { [weak self] type, payload in
            await self?.send(type: type, payload: payload)
        }
        self.exporter = exporter
        cursorOverlay.setSharingActive(true)
        eventTask = Task { @MainActor [weak self] in
            await self?.runEventLoop(initialIterator: iterator)
        }
        tabsCancellable = tabManager.tabsPublisher.sink { [weak self] tabs in
            guard let self, !tabs.contains(where: { $0.id == self.workspaceID }) else { return }
            self.onWorkspaceClosed()
        }
        await exporter.start()
    }

    func stop() async {
        stopping = true
        // The authenticated host socket revokes the room even when the Stack
        // account has just changed and a fresh owner bearer is unavailable.
        try? await client.send(type: "share.end", payload: .object([:]))
        eventTask?.cancel()
        eventTask = nil
        tabsCancellable = nil
        exporter?.stop()
        exporter = nil
        promptCoordinator.cancelAll()
        cursorOverlay.uninstall()
        await client.disconnect(reason: "host_closed")
    }

    private func connect(
        accessToken: String
    ) async throws -> AsyncStream<WorkspaceShareEvent>.Iterator {
        let events = await client.connect(session: session, accessToken: accessToken)
        var iterator = events.makeAsyncIterator()
        guard let first = await iterator.next() else { throw WorkspaceShareError.unavailable }
        switch first {
        case let .frame(frame) where frame.type == "host.ready":
            return iterator
        case let .disconnected(reason):
            throw WorkspaceShareError.transport(reason)
        default:
            throw WorkspaceShareError.invalidResponse
        }
    }

    private func runEventLoop(initialIterator: AsyncStream<WorkspaceShareEvent>.Iterator) async {
        var iterator = initialIterator
        while !Task.isCancelled, !stopping {
            eventStream: while let event = await iterator.next() {
                guard !Task.isCancelled, !stopping else { return }
                switch event {
                case .disconnected:
                    break eventStream
                case let .frame(frame):
                    await handle(frame)
                    if frame.type == "share.ended" { return }
                }
            }
            guard !Task.isCancelled, !stopping,
                  let reconnected = await reconnectWithinGrace() else {
                if !Task.isCancelled, !stopping { onWorkspaceClosed() }
                return
            }
            iterator = reconnected
            await exporter?.sendSnapshot()
        }
    }

    private func reconnectWithinGrace() async -> AsyncStream<WorkspaceShareEvent>.Iterator? {
        let deadline = Date().addingTimeInterval(110)
        var delay: UInt64 = 500_000_000
        while Date() < deadline, !Task.isCancelled, !stopping {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, !stopping else { return nil }
            do {
                let accessToken = try await accessTokenProvider()
                return try await connect(accessToken: accessToken)
            } catch {
                delay = min(delay * 2, 8_000_000_000)
            }
        }
        return nil
    }

    private func handle(_ frame: WorkspaceShareWireFrame) async {
        switch frame.type {
        case "access.requested":
            guard let request = try? frame.payload.decode(WorkspaceShareAccessRequest.self) else { return }
            promptCoordinator.enqueue(request) { [weak self] allowed in
                guard let self else { return }
                let decision = AccessDecisionPayload(
                    userId: request.userId,
                    decision: allowed ? "allow" : "deny"
                )
                guard let payload = try? WorkspaceShareJSONValue.encode(decision) else { return }
                Task { @MainActor in await self.send(type: "access.decision", payload: payload) }
            }
        case "workspace.snapshot.request":
            await exporter?.sendSnapshot()
        case "textbox.operation.request":
            guard let request = try? frame.payload.decode(TextOperationRequestPayload.self) else { return }
            guard let result = exporter?.applyRemoteTextOperation(
                request.operation,
                clientID: request.participant.connectionId
            ) else { return }
            switch result {
            case let .accepted(operation, revision):
                let response = TextOperationAcceptedPayload(
                    operation: operation,
                    revision: revision
                )
                if let payload = try? WorkspaceShareJSONValue.encode(response) {
                    await send(type: "textbox.operation", payload: payload)
                }
            case .deferred:
                break
            case let .rejected(snapshot):
                if let snapshot,
                   let payload = try? WorkspaceShareJSONValue.encode(TextDocumentPayload(document: snapshot)) {
                    await send(type: "textbox.document", payload: payload)
                }
            }
        case "terminal.input.request":
            guard let request = try? frame.payload.decode(TerminalInputRequestPayload.self),
                  request.participant.role == "viewer" else { return }
            _ = exporter?.applyRemoteTerminalInput(request.input)
        case "textbox.selection":
            guard let selection = try? frame.payload.decode(WorkspaceShareTextSelection.self) else { return }
            exporter?.updateRemoteTextSelection(selection)
        case "presence.pointer":
            guard let pointer = try? frame.payload.decode(WorkspaceShareRemotePointer.self) else { return }
            exporter?.updateRemotePointer(pointer)
        case "presence.left":
            guard let payload = try? frame.payload.decode(PresenceLeftPayload.self) else { return }
            exporter?.removeRemotePointer(connectionID: payload.participant.connectionId)
        case "chat.message":
            guard let message = try? frame.payload.decode(WorkspaceShareChatMessage.self) else { return }
            exporter?.updateRemoteChat(message)
        case "chat.snapshot":
            guard let snapshot = try? frame.payload.decode(ChatSnapshotPayload.self) else { return }
            cursorOverlay.replaceChat(messages: snapshot.messages)
        case "share.ended":
            onWorkspaceClosed()
        default:
            break
        }
    }

    private func send(type: String, payload: WorkspaceShareJSONValue) async {
        try? await client.send(type: type, payload: payload)
    }
}

private struct AccessDecisionPayload: Encodable, Sendable {
    let userId: String
    let decision: String
}

private struct TextOperationRequestPayload: Decodable, Sendable {
    let operation: WorkspaceShareTextOperation
    let participant: WorkspaceShareRemotePointer.Participant
}

private struct TerminalInputRequestPayload: Decodable, Sendable {
    let input: WorkspaceShareTerminalInput
    let participant: WorkspaceShareRemotePointer.Participant
}

private struct TextOperationAcceptedPayload: Encodable, Sendable {
    let operation: WorkspaceShareTextOperation
    let revision: UInt64
}

private struct TextDocumentPayload: Encodable, Sendable {
    let document: WorkspaceShareTextSnapshot
}

private struct PresenceLeftPayload: Decodable, Sendable {
    let participant: WorkspaceShareRemotePointer.Participant
}

private struct ChatSnapshotPayload: Decodable, Sendable {
    let messages: [WorkspaceShareChatMessage]
}

private struct ChatSendPayload: Encodable, Sendable {
    let text: String
}
