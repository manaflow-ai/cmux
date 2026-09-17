import AppKit
import CmuxWorkspaceShare
import CmuxWorkspaces
import Combine
import Foundation

@MainActor
final class WorkspaceShareHostSession {
    let session: WorkspaceShareSession
    let workspaceID: UUID

    private weak var workspace: Workspace?
    private weak var tabManager: TabManager?
    private let client: WorkspaceShareClient
    private lazy var cursorOverlay = WorkspaceShareCursorOverlayController(window: tabManager?.window)
    private lazy var chatModel = WorkspaceShareChatModel(
        shareURL: session.shareUrl,
        decisionSender: { [weak self] userID, decision in
            guard let self else { throw WorkspaceShareError.unavailable }
            try await self.sendAccessDecision(userID: userID, decision: decision)
        },
        onSendChat: { [weak self] text in
            guard let self,
                  let payload = try? WorkspaceShareJSONValue.encode(ChatSendPayload(text: text)) else { return }
            Task { @MainActor in await self.send(type: "chat.message", payload: payload) }
        },
        onStopSharing: { [weak self] in
            self?.requestClose()
        }
    )
    private lazy var chatPanel = WorkspaceShareChatPanel(model: chatModel)
    private let accessTokenProvider: @MainActor @Sendable () async throws -> String
    private let onWorkspaceClosed: @MainActor () -> Void
    private var exporter: WorkspaceShareExporter?
    private var eventTask: Task<Void, Never>?
    private var tabsCancellable: AnyCancellable?
    private var windowCloseObserver: NSObjectProtocol?
    private var chatDockID: UUID?
    private var chatSurfaceStarted = false
    private var closeRequested = false
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
        self.accessTokenProvider = accessTokenProvider
        self.onWorkspaceClosed = onWorkspaceClosed
    }

    func start(accessToken: String) async throws {
        stopping = false
        let iterator = try await connect(accessToken: accessToken)
        guard let workspace, let tabManager else { throw WorkspaceShareError.unavailable }
        guard ensureChatDock(focus: true) else { throw WorkspaceShareError.unavailable }
        chatSurfaceStarted = true
        let exporter = WorkspaceShareExporter(
            workspace: workspace,
            tabManager: tabManager,
            cursorOverlay: cursorOverlay
        ) { [weak self] type, payload in
            await self?.send(type: type, payload: payload)
        }
        self.exporter = exporter
        eventTask = Task { @MainActor [weak self] in
            await self?.runEventLoop(initialIterator: iterator)
        }
        tabsCancellable = tabManager.tabsPublisher.sink { [weak self] tabs in
            guard let self, !tabs.contains(where: { $0.id == self.workspaceID }) else { return }
            self.requestClose()
        }
        if let window = tabManager.window {
            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestClose() }
            }
        }
        await exporter.start()
        guard !stopping else { throw WorkspaceShareError.unavailable }
    }

    func stop() async {
        guard !stopping else { return }
        stopping = true
        eventTask?.cancel()
        eventTask = nil
        tabsCancellable = nil
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        let unresolvedRequests = chatSurfaceStarted ? chatModel.freezeAndDrainPending() : []
        for request in unresolvedRequests {
            try? await sendAccessDecision(userID: request.userId, decision: .deny, allowsStopping: true)
        }
        // The authenticated host socket revokes the room even when the Stack
        // account has just changed and a fresh owner bearer is unavailable.
        try? await client.send(type: "share.end", payload: .object([:]))
        exporter?.stop()
        exporter = nil
        cursorOverlay.uninstall()
        removeChatDock()
        await client.disconnect(reason: "host_closed")
    }

    func showChat() {
        guard !stopping else { return }
        _ = ensureChatDock(focus: true)
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
                if !Task.isCancelled, !stopping { requestClose() }
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
            switch chatModel.receive(request) {
            case .queued, .duplicate:
                chatSurfaceStarted = true
                showChat()
            case .deniedOverflow:
                Task { @MainActor [weak self] in
                    try? await self?.sendAccessDecision(userID: request.userId, decision: .deny)
                }
            case .ignoredAfterStop:
                break
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
            chatModel.append(message)
            exporter?.updateRemoteChat(message)
        case "chat.snapshot":
            guard let snapshot = try? frame.payload.decode(ChatSnapshotPayload.self) else { return }
            chatModel.replaceMessages(snapshot.messages)
            cursorOverlay.replaceChat(messages: snapshot.messages)
        case "share.ended":
            requestClose()
        default:
            break
        }
    }

    private func send(type: String, payload: WorkspaceShareJSONValue) async {
        try? await client.send(type: type, payload: payload)
    }

    private func sendAccessDecision(
        userID: String,
        decision: WorkspaceShareAccessDecision,
        allowsStopping: Bool = false
    ) async throws {
        guard !stopping || allowsStopping else { throw WorkspaceShareError.unavailable }
        let decision = AccessDecisionPayload(userId: userID, decision: decision.rawValue)
        let payload = try WorkspaceShareJSONValue.encode(decision)
        try await client.send(type: "access.decision", payload: payload)
    }

    @discardableResult
    private func ensureChatDock(focus: Bool) -> Bool {
        guard let workspace, let tabManager else { return false }
        if focus, tabManager.selectedTabId != workspaceID {
            tabManager.selectTab(workspace)
        }
        if let chatDockID,
           let dock = workspace.floatingDock(id: chatDockID),
           dock.store.containsPanel(chatPanel.id) {
            dock.isPresented = true
            AppDelegate.shared?.refreshWorkspaceFloatingDocks(
                for: tabManager,
                focusDockId: focus ? dock.id : nil
            )
            return true
        }
        if let chatDockID {
            _ = workspace.closeFloatingDock(id: chatDockID)
            self.chatDockID = nil
        }
        guard let dock = workspace.createFloatingDock(
            title: String(localized: "workspaceShare.chat.title", defaultValue: "Workspace chat"),
            isPresented: true,
            persistence: .transient,
            closeBehavior: .hide,
            contentPolicy: .fixed,
            seedsDefaultNote: false
        ), dock.store.installRuntimePanel(
            chatPanel,
            surfaceKind: SurfaceKind.workspaceShareChat.rawValue,
            focus: false
        ) != nil else { return false }
        chatDockID = dock.id
        AppDelegate.shared?.refreshWorkspaceFloatingDocks(
            for: tabManager,
            focusDockId: focus ? dock.id : nil
        )
        return true
    }

    private func removeChatDock() {
        guard let workspace, let chatDockID else { return }
        _ = workspace.closeFloatingDock(id: chatDockID)
        self.chatDockID = nil
        if let tabManager {
            AppDelegate.shared?.refreshWorkspaceFloatingDocks(for: tabManager)
        }
    }

    private func requestClose() {
        guard !closeRequested else { return }
        closeRequested = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stop()
            self.onWorkspaceClosed()
        }
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
