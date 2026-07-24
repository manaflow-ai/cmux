import AppKit
import Combine
import CmuxAuthRuntime
import CmuxWorkspaceShare
import Foundation
import Observation
import os

nonisolated private let shareSessionLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "WorkspaceShareSession"
)

/// One live-share feed entry: a chat message or an inline access request.
struct ShareFeedItem: Identifiable, Equatable {
    enum AccessResolution: Equatable {
        case approvedEditor
        case approvedViewer
        case denied
    }

    enum Kind: Equatable {
        case chat(user: String, email: String, colorIndex: Int, text: String, hasBubble: Bool)
        case accessRequest(user: String, email: String, resolution: AccessResolution?)
    }

    let id: String
    var kind: Kind

    var isChat: Bool {
        if case .chat = kind { return true }
        return false
    }

    var isPendingAccessRequest: Bool {
        if case .accessRequest(_, _, .none) = kind { return true }
        return false
    }

    var rawChatID: String? {
        guard isChat, id.hasPrefix("chat:") else { return nil }
        return String(id.dropFirst("chat:".count))
    }
}

/// Orchestrates one multiplayer share session: session creation, the DO
/// socket, layout observation, terminal grid streaming, guest input,
/// moderation, and cursor overlays.
@MainActor
@Observable
final class ShareSessionController {
    enum Status: Equatable {
        case idle
        case starting
        case active
        case reconnecting
    }

    private(set) var status: Status = .idle
    private(set) var shareUrl: String?
    private(set) var code: String?
    private(set) var participants: [ShareParticipant] = []
    private(set) var feed: [ShareFeedItem] = []
    private(set) var lastErrorText: String?

    var isSharing: Bool { status != .idle }

    private(set) var sharedWorkspaceIDs: Set<UUID> = []
    private(set) weak var tabManager: TabManager?
    @ObservationIgnored
    private let apiProvider:
        @MainActor () -> (any ShareSessionAPIProviding)?
    @ObservationIgnored
    private var api: (any ShareSessionAPIProviding)?
    @ObservationIgnored
    private(set) var socket: ShareSocket?
    @ObservationIgnored
    let streamer = ShareGridStreamer()
    @ObservationIgnored
    private let cursorOverlay = ShareCursorOverlayController()
    @ObservationIgnored
    private var chatWindow: ShareChatWindowController?
    @ObservationIgnored
    private var startTask: Task<Void, Never>?
    @ObservationIgnored
    private var socketEventTask: Task<Void, Never>?
    @ObservationIgnored
    private var socketStopTask: Task<Void, Never>?
    @ObservationIgnored
    private var globalCancellables = Set<AnyCancellable>()
    @ObservationIgnored
    private var perWorkspaceCancellables: [UUID: AnyCancellable] = [:]
    @ObservationIgnored
    private var lastSentShared: [ShareSharedWorkspace] = []
    @ObservationIgnored
    private var lastSentLayouts: [String: ShareWorkspaceLayout] = [:]
    @ObservationIgnored
    private var lastSentFocusWs: String??
    @ObservationIgnored
    private var acknowledgementGate = WorkspaceShareAcknowledgementGate()
    @ObservationIgnored
    private let inboundValidator = WorkspaceShareInboundMessageValidator()
    @ObservationIgnored
    private let outboundValidator = WorkspaceShareOutboundMessageValidator()
    @ObservationIgnored
    private var shouldTeardownAfterAcknowledgement = false
    @ObservationIgnored
    private var pendingResyncHello: ShareHostMessage?
    @ObservationIgnored
    private var activeSocketConnection: UInt64?
    @ObservationIgnored
    private var accessRequestSequence: UInt64 = 0
    @ObservationIgnored
    private var retainedChatIDs = Set<String>()
    @ObservationIgnored
    private var retainedChatCount = 0
    @ObservationIgnored
    private var nextStartGeneration: UInt64 = 1
    @ObservationIgnored
    private var activeStartGeneration: UInt64?
    private static let layoutThrottleMilliseconds = 100
    private static let maximumFeedItems =
        ShareProtocolConstants.maximumChatMessages
        + ShareProtocolConstants.maximumPendingAccessRequests
    private let inputAuthorizer = WorkspaceShareInputAuthorizer()

    init(authCoordinator: @escaping @MainActor () -> AuthCoordinator?) {
        self.apiProvider = {
            guard let coordinator = authCoordinator() else { return nil }
            return ShareSessionAPI(auth: coordinator)
        }
    }

#if DEBUG
    init(testingAPI: any ShareSessionAPIProviding) {
        self.apiProvider = { testingAPI }
    }
#endif

    // MARK: - Lifecycle

    func startSharing(tabManager: TabManager, focusedWorkspace: Workspace) {
        if isSharing {
            showChatWindow()
            return
        }
        showChatWindow()
        lastErrorText = nil
        guard tabManager.selectedTabId == focusedWorkspace.id,
              tabManager.tabs.contains(where: { $0 === focusedWorkspace }) else {
            lastErrorText = String(
                localized: "share.error.noWorkspaceContext",
                defaultValue: "Sharing is unavailable: no workspace window is open."
            )
            return
        }
        guard let api = apiProvider() else {
            lastErrorText = String(
                localized: "share.error.notSignedIn",
                defaultValue: "Sign in to cmux to share a workspace."
            )
            return
        }
        self.tabManager = tabManager
        sharedWorkspaceIDs = [focusedWorkspace.id]
        lastErrorText = nil
        status = .starting
        self.api = api
        let generation = nextStartGeneration
        nextStartGeneration &+= 1
        activeStartGeneration = generation
        startTask = Task { @MainActor [weak self] in
            do {
                let created = try await api.createSession()
                guard let self,
                      self.status == .starting,
                      self.activeStartGeneration == generation else {
                    return
                }
                self.activeStartGeneration = nil
                self.activate(created: created, api: api)
            } catch {
                guard let self,
                      self.status == .starting,
                      self.activeStartGeneration == generation else {
                    return
                }
                self.activeStartGeneration = nil
                self.status = .idle
                self.startTask = nil
                self.api = nil
                self.tabManager = nil
                self.sharedWorkspaceIDs = []
                shareSessionLogger.error("Starting a workspace share session failed")
                self.lastErrorText = Self.startFailureText(for: error)
            }
        }
    }

    private static func startFailureText(for error: Error) -> String {
        if let shareError = error as? ShareSessionAPIError,
           case .notSignedIn = shareError {
            return String(
                localized: "share.error.notSignedIn",
                defaultValue: "Sign in to cmux to share a workspace."
            )
        }
        return String(
            localized: "share.error.startFailed",
            defaultValue: "Couldn't start sharing. Check your connection and try again."
        )
    }

    func stopSharing() {
        guard isSharing else { return }
        teardownSession(finalMessage: .end)
    }

    /// Stops only the session owned by the exact per-window manager being
    /// retired. Closing another main window must not affect the process-wide
    /// session.
    @discardableResult
    func stopSharing(ifOwnedBy candidate: TabManager) -> Bool {
        guard tabManager === candidate else { return false }
        teardownSession(finalMessage: isSharing ? .end : nil)
        return true
    }

#if DEBUG
    /// Creates an owner-bound, socket-free starting state for window-lifecycle
    /// integration tests.
    func bindOwnerForWindowLifecycleTesting(_ owner: TabManager) {
        precondition(status == .idle)
        tabManager = owner
        status = .starting
    }
#endif

    private func activate(
        created: ShareSessionCreateResult,
        api: any ShareSessionAPIProviding
    ) {
        guard let tabManager, sharedWorkspace(in: tabManager) != nil else {
            lastErrorText = String(
                localized: "share.error.noWorkspaceContext",
                defaultValue: "Sharing is unavailable: no workspace window is open."
            )
            teardownSession(closeChatWindow: false)
            return
        }
        startTask = nil
        code = created.code
        shareUrl = created.shareUrl
        copyShareLink()
        wireCursorOverlay()
        streamer.sendBinary = { [weak self] data in
            self?.socket?.send(data: data).wasAdmitted ?? false
        }
        streamer.start()
        attachLayoutObservation(tabManager: tabManager)

        let code = created.code
        let socket = ShareSocket(
            endpoint: ShareSocket.Endpoint(wsUrl: created.wsUrl, token: created.token),
            refresh: {
                let refreshed = try await api.hostToken(code: code)
                return ShareSocket.Endpoint(wsUrl: refreshed.wsUrl, token: refreshed.token)
            }
        )
        self.socket = socket
        socketEventTask = Task { @MainActor [weak self, events = socket.events] in
            await socket.start()
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .opened(let connection):
                    guard self.isSharing else { continue }
                    self.activeSocketConnection = connection
                    self.acknowledgementGate.connectionOpened()
                    self.shouldTeardownAfterAcknowledgement = false
                    self.pendingResyncHello = nil
                    self.status = .active
                    _ = self.sendHello()
                case .text(let text, let connection, let sequence):
                    guard self.activeSocketConnection == connection else {
                        continue
                    }
                    await self.handleServerText(
                        text,
                        connection: connection,
                        sequence: sequence
                    )
                case .connectionStateChanged(let connected):
                    if !connected, self.isSharing {
                        self.activeSocketConnection = nil
                        self.status = .reconnecting
                    }
                case .stopped:
                    if self.isSharing {
                        self.teardownSession()
                    }
                }
            }
            guard let self,
                  !Task.isCancelled,
                  self.socket === socket,
                  self.isSharing else {
                return
            }
            self.teardownSession()
        }
        showChatWindow()
    }

    private func teardownSession(
        finalMessage: ShareHostMessage? = nil,
        closeChatWindow: Bool = true
    ) {
        startTask?.cancel()
        startTask = nil
        activeStartGeneration = nil
        socketEventTask?.cancel()
        socketEventTask = nil
        socketStopTask?.cancel()
        if let socket {
            socketStopTask = Task { @MainActor in
                if let finalMessage {
                    await socket.sendAndStop(finalMessage)
                } else {
                    await socket.stop()
                }
            }
        }
        socket = nil
        streamer.stop()
        streamer.sendBinary = nil
        cursorOverlay.teardown()
        globalCancellables.removeAll()
        perWorkspaceCancellables.removeAll()
        if closeChatWindow {
            chatWindow?.close()
            chatWindow = nil
        }
        status = .idle
        code = nil
        shareUrl = nil
        participants = []
        feed = []
        sharedWorkspaceIDs = []
        lastSentShared = []
        lastSentLayouts = [:]
        lastSentFocusWs = nil
        acknowledgementGate.connectionOpened()
        shouldTeardownAfterAcknowledgement = false
        pendingResyncHello = nil
        activeSocketConnection = nil
        accessRequestSequence = 0
        retainedChatIDs.removeAll(keepingCapacity: true)
        retainedChatCount = 0
        api = nil
        tabManager = nil
    }

    // MARK: - Chat window actions

    private func showChatWindow() {
        let window = chatWindow ?? ShareChatWindowController(controller: self)
        chatWindow = window
        window.show()
    }

    func showSessionPanel() {
        showChatWindow()
    }

    func copyShareLink() {
        guard let shareUrl else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(shareUrl, forType: .string)
    }

    @discardableResult
    func sendChat(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == .active, !trimmed.isEmpty else { return false }
        // The DO echoes chat back to every active connection (including the
        // sender), so the echo is the single append path.
        return socket?.send(.chat(text: trimmed, bubble: nil)) == .admitted
    }

    func approve(user: String, role: ShareRole) {
        guard socket?.send(.approve(user: user, role: role)) == .admitted else {
            return
        }
        resolveAccessRequest(user: user, resolution: role == .editor ? .approvedEditor : .approvedViewer)
    }

    func deny(user: String) {
        guard socket?.send(.deny(user: user)) == .admitted else { return }
        resolveAccessRequest(user: user, resolution: .denied)
    }

    func kick(user: String) {
        guard socket?.send(.kick(user: user)) == .admitted else { return }
        cursorOverlay.removeRemoteUser(user)
    }

    func setRole(user: String, role: ShareRole) {
        socket?.send(.role(user: user, role: role))
    }

    private func resolveAccessRequest(user: String, resolution: ShareFeedItem.AccessResolution) {
        for index in feed.indices {
            if case .accessRequest(let requestUser, let email, _) = feed[index].kind,
               requestUser == user {
                feed[index].kind = .accessRequest(user: requestUser, email: email, resolution: resolution)
            }
        }
    }

    // MARK: - Outbound sync

    @discardableResult
    private func sendHello() -> Bool {
        guard let tabManager,
              let workspace = sharedWorkspace(in: tabManager),
              let socket else {
            return false
        }
        let shared = [ShareLayoutSerializer.sharedWorkspace(for: workspace)]
        let layouts = [ShareLayoutSerializer.layout(for: workspace)]
        let result = socket.send(.hello(shared: shared, layouts: layouts))
        switch result {
        case .admitted:
            lastSentShared = shared
            lastSentLayouts = Dictionary(
                uniqueKeysWithValues: layouts.map { ($0.ws, $0) }
            )
            lastSentFocusWs = nil
        case .invalid:
            failInvalidShareLayout()
            return false
        case .backpressured:
            return false
        }
        sendFocusIfChanged()
        return true
    }

    private func sharedWorkspace(in tabManager: TabManager) -> Workspace? {
        guard let sharedWorkspaceID = sharedWorkspaceIDs.first,
              sharedWorkspaceIDs.count == 1 else {
            return nil
        }
        return tabManager.tabs.first { $0.id == sharedWorkspaceID }
    }

    private func attachLayoutObservation(tabManager: TabManager) {
        tabManager.tabsPublisher
            .throttle(
                for: .milliseconds(Self.layoutThrottleMilliseconds),
                scheduler: RunLoop.main,
                latest: true
            )
            .sink { [weak self] tabs in
                guard let self else { return }
                self.refreshPerWorkspaceSubscriptions(tabs: tabs)
                self.syncSharedAndLayouts()
            }
            .store(in: &globalCancellables)
        tabManager.selectedTabIdPublisher
            .throttle(
                for: .milliseconds(Self.layoutThrottleMilliseconds),
                scheduler: RunLoop.main,
                latest: true
            )
            .sink { [weak self] _ in
                guard let self else { return }
                self.cursorOverlay.refreshAll()
                self.sendFocusIfChanged()
            }
            .store(in: &globalCancellables)
        refreshPerWorkspaceSubscriptions(tabs: tabManager.tabs)
    }

    private func refreshPerWorkspaceSubscriptions(tabs: [Workspace]) {
        guard let sharedWorkspaceID = sharedWorkspaceIDs.first else {
            perWorkspaceCancellables.removeAll()
            return
        }
        for id in perWorkspaceCancellables.keys where id != sharedWorkspaceID {
            perWorkspaceCancellables.removeValue(forKey: id)
        }
        for workspace in tabs
        where workspace.id == sharedWorkspaceID
            && perWorkspaceCancellables[workspace.id] == nil {
            let publishers: [AnyPublisher<Void, Never>] = [
                workspace.panelsPublisher.map { _ in () }.eraseToAnyPublisher(),
                workspace.paneLayoutVersionPublisher.map { _ in () }.eraseToAnyPublisher(),
                workspace.$panelTitles.map { _ in () }.eraseToAnyPublisher(),
                workspace.$panelCustomTitles.map { _ in () }.eraseToAnyPublisher(),
                workspace.$title.map { _ in () }.eraseToAnyPublisher(),
            ]
            perWorkspaceCancellables[workspace.id] = Publishers.MergeMany(publishers)
                .throttle(
                    for: .milliseconds(Self.layoutThrottleMilliseconds),
                    scheduler: RunLoop.main,
                    latest: true
                )
                .sink { [weak self] _ in
                    self?.syncSharedAndLayouts()
                }
        }
    }

    /// Re-serializes shared workspaces and sends `shared`/`layout` messages
    /// for whatever actually changed. Cheap when nothing did.
    private func syncSharedAndLayouts() {
        guard isSharing, let tabManager else { return }
        guard let workspace = sharedWorkspace(in: tabManager) else {
            teardownSession()
            return
        }
        let shared = [ShareLayoutSerializer.sharedWorkspace(for: workspace)]
        if shared != lastSentShared {
            guard let socket else { return }
            switch socket.send(.shared(shared)) {
            case .admitted:
                lastSentShared = shared
            case .invalid:
                failInvalidShareLayout()
                return
            case .backpressured:
                return
            }
        }
        let layout = ShareLayoutSerializer.layout(for: workspace)
        let nextLayouts = [layout.ws: layout]
        if lastSentLayouts[layout.ws] != layout {
            guard let socket else { return }
            switch socket.send(.layout(layout)) {
            case .admitted:
                break
            case .invalid:
                failInvalidShareLayout()
                return
            case .backpressured:
                return
            }
        }
        lastSentLayouts = nextLayouts
        cursorOverlay.refreshAll()
        sendFocusIfChanged()
    }

    private func sendFocusIfChanged() {
        guard isSharing, let tabManager else { return }
        let focusWs: String? = tabManager.selectedTabId
            .flatMap { sharedWorkspaceIDs.contains($0) ? $0.uuidString : nil }
        if lastSentFocusWs != .some(focusWs) {
            guard socket?.send(.focus(ws: focusWs)) == .admitted else {
                return
            }
            lastSentFocusWs = .some(focusWs)
        }
    }

    private func failInvalidShareLayout() {
        lastErrorText = String(
            localized: "share.error.layoutTooComplex",
            defaultValue: "This workspace layout is too complex to share."
        )
        teardownSession(closeChatWindow: false)
    }

    // MARK: - Inbound

    private func handleServerText(
        _ text: String,
        connection: UInt64,
        sequence: UInt64
    ) async {
        guard WorkspaceShareTextFramePolicy.acceptsServerFrame(
            byteCount: text.utf8.count
        ),
        let data = text.data(using: .utf8),
        let message = try? JSONDecoder().decode(ShareServerMessage.self, from: data) else {
            socket?.discardAcknowledgementBarrier()
            acknowledgementGate.recordPayload(accepted: false, sequence: sequence)
            shouldTeardownAfterAcknowledgement = false
            pendingResyncHello = nil
            return
        }

        if case .ackRequest(let nonce) = message {
            guard let acknowledgedNonce = acknowledgementGate.acknowledgement(
                for: nonce,
                sequence: sequence
            ) else {
                socket?.discardAcknowledgementBarrier()
                shouldTeardownAfterAcknowledgement = false
                pendingResyncHello = nil
                return
            }
            if shouldTeardownAfterAcknowledgement {
                teardownSession(finalMessage: .ack(nonce: acknowledgedNonce))
            } else {
                let didAdmitAcknowledgement =
                    socket?.send(.ack(nonce: acknowledgedNonce)) == .admitted
                if !didAdmitAcknowledgement {
                    socket?.discardAcknowledgementBarrier()
                }
                if didAdmitAcknowledgement,
                   let pendingResyncHello,
                   case .hello(let shared, let layouts) = pendingResyncHello {
                    if socket?.sendResyncHello(
                        shared: shared,
                        layouts: layouts
                    ) == .admitted {
                        lastSentFocusWs = nil
                        sendFocusIfChanged()
                        streamer.resendFullFrames()
                    }
                }
            }
            pendingResyncHello = nil
            return
        }

        // Any normalized non-marker frame displaces the previous payload's
        // credit. Start the replacement barrier before applying the payload
        // so synchronous effects cannot overtake its adjacent ACK.
        socket?.beginAcknowledgementBarrier()
        guard inboundValidator.acceptsPayload(message) else {
            socket?.discardAcknowledgementBarrier()
            acknowledgementGate.recordPayload(accepted: false, sequence: sequence)
            shouldTeardownAfterAcknowledgement = false
            pendingResyncHello = nil
            return
        }

        shouldTeardownAfterAcknowledgement = false
        pendingResyncHello = nil
        let accepted = acceptServerPayload(message)
        acknowledgementGate.recordPayload(accepted: accepted, sequence: sequence)
        if accepted,
           case .sessionState = message,
           let socket {
            await socket.sessionSynchronized(connection: connection)
        }
        if !accepted {
            socket?.discardAcknowledgementBarrier()
            shouldTeardownAfterAcknowledgement = false
            pendingResyncHello = nil
        }
    }

    /// Applies one already-bounded payload and reports whether it entered the
    /// live controller path. Semantic rejection does not earn ACK credit.
    private func acceptServerPayload(_ message: ShareServerMessage) -> Bool {
        switch message {
        case .sessionState(let snapshot):
            participants = snapshot.participants
            rebuildFeed(chat: snapshot.chat)
            pruneCursors()
            return true
        case .accessRequest(let user, let email):
            return appendAccessRequest(user: user, email: email)
        case .presence(let updated):
            participants = updated
            pruneCursors()
            return true
        case .cursor(let user, let pos):
            guard let participant = participant(user) else { return false }
            cursorOverlay.updateRemoteCursor(
                user: user,
                email: participant.email,
                colorIndex: participant.color,
                pos: pos
            )
            return true
        case .chat(let message):
            return appendChat(message)
        case .guestInput(let user, let ws, let pane, let data):
            return applyGuestInput(user: user, ws: ws, pane: pane, data: data)
        case .guestSub(let ws, let pane, let count):
            return routeGuestSub(ws: ws, pane: pane, count: count)
        case .resync:
            guard let tabManager,
                  let workspace = sharedWorkspace(in: tabManager) else {
                return false
            }
            let hello = ShareHostMessage.hello(
                shared: [ShareLayoutSerializer.sharedWorkspace(for: workspace)],
                layouts: [ShareLayoutSerializer.layout(for: workspace)]
            )
            guard let prepared = outboundValidator.prepareForTransport(hello)
            else {
                failInvalidShareLayout()
                return false
            }
            pendingResyncHello = prepared
            return true
        case .sessionEnded:
            shouldTeardownAfterAcknowledgement = true
            return true
        case .error:
            shareSessionLogger.warning("The workspace-share relay reported an error")
            lastErrorText = String(
                localized: "share.error.sessionError",
                defaultValue: "The share session hit an error. Reconnecting…"
            )
            return true
        case .ackRequest, .unknown:
            return false
        }
    }

    func participant(_ user: String) -> ShareParticipant? {
        participants.first { $0.user == user }
    }

    private func pruneCursors() {
        let connected = Set(participants.filter(\.connected).map(\.user))
        for user in cursorOverlay.remoteUserIDs.subtracting(connected) {
            cursorOverlay.removeRemoteUser(user)
        }
    }

    private func rebuildFeed(chat: [ShareChatMessage]) {
        var items = chat.map(feedItem(for:))
        // Keep unresolved access requests visible across a session-state
        // snapshot (the DO does not persist them into chat history).
        let pendingRequests = feed.filter { item in
            if case .accessRequest(_, _, .none) = item.kind { return true }
            return false
        }
        items.append(
            contentsOf: pendingRequests.prefix(
                ShareProtocolConstants.maximumPendingAccessRequests
            )
        )
        feed = Array(items.suffix(Self.maximumFeedItems))
        retainedChatIDs = Set(chat.map(\.id))
        retainedChatCount = chat.count
    }

    private func appendChat(_ message: ShareChatMessage) -> Bool {
        guard !retainedChatIDs.contains(message.id) else { return true }
        if retainedChatCount >= ShareProtocolConstants.maximumChatMessages,
           let oldestChatIndex = feed.firstIndex(where: \.isChat) {
            removeFeedItem(at: oldestChatIndex)
        }
        guard makeFeedRoom() else { return false }
        presentRemoteBubbleIfEligible(message)
        feed.append(feedItem(for: message))
        retainedChatIDs.insert(message.id)
        retainedChatCount += 1
        return true
    }

    private func presentRemoteBubbleIfEligible(_ message: ShareChatMessage) {
        guard let anchor = message.bubble,
              let sender = participant(message.user),
              sender.connected,
              !sender.isHost else {
            return
        }
        cursorOverlay.showRemoteBubble(
            user: sender.user,
            email: sender.email,
            colorIndex: sender.color,
            text: message.text,
            anchor: anchor
        )
    }

    private func feedItem(for message: ShareChatMessage) -> ShareFeedItem {
        let sender = participant(message.user)
        return ShareFeedItem(
            id: "chat:\(message.id)",
            kind: .chat(
                user: message.user,
                email: sender?.email ?? message.user,
                colorIndex: sender?.color ?? 0,
                text: message.text,
                hasBubble: message.bubble != nil
            )
        )
    }

    private func appendAccessRequest(user: String, email: String) -> Bool {
        // A repeat request from the same still-pending user collapses into one
        // actionable item.
        let hasPending = feed.contains { item in
            if case .accessRequest(let requestUser, _, .none) = item.kind {
                return requestUser == user
            }
            return false
        }
        guard !hasPending else { return true }
        let pendingCount = feed.lazy.filter(\.isPendingAccessRequest).count
        guard pendingCount < ShareProtocolConstants.maximumPendingAccessRequests,
              makeFeedRoom() else {
            return false
        }
        let sequence = accessRequestSequence
        accessRequestSequence &+= 1
        feed.append(ShareFeedItem(
            id: "access-request:\(sequence):\(user)",
            kind: .accessRequest(user: user, email: email, resolution: nil)
        ))
        return true
    }

    private func makeFeedRoom() -> Bool {
        guard feed.count >= Self.maximumFeedItems else { return true }
        guard let disposableIndex = feed.firstIndex(where: {
            !$0.isPendingAccessRequest
        }) else {
            return false
        }
        removeFeedItem(at: disposableIndex)
        return true
    }

    private func removeFeedItem(at index: Int) {
        let item = feed.remove(at: index)
        guard let rawChatID = item.rawChatID else { return }
        retainedChatIDs.remove(rawChatID)
        retainedChatCount = max(0, retainedChatCount - 1)
    }

    /// Applies guest terminal input. The host is the only input authority:
    /// the workspace must be in the shared set and the sender's locally-known
    /// role must be `editor`, regardless of what the DO forwarded.
    private func applyGuestInput(user: String, ws: String, pane: String, data: String) -> Bool {
        guard !data.isEmpty,
              let wsUUID = UUID(uuidString: ws),
              let tabManager,
              let workspace = sharedWorkspace(in: tabManager),
              workspace.id == wsUUID,
              let paneUUID = UUID(uuidString: pane),
              let terminalPanel = workspace.terminalPanel(for: paneUUID),
              let role = participant(user)?.role else {
            return false
        }
        let currentTerminalPaneIDs = workspace.panels.values.compactMap {
            ($0 as? TerminalPanel)?.surface.id
        }
        guard inputAuthorizer.allowsTerminalInput(
            from: role,
            workspaceID: wsUUID,
            paneID: paneUUID,
            sharedWorkspaceIDs: sharedWorkspaceIDs,
            currentTerminalPaneIDs: currentTerminalPaneIDs
        ) else {
            return false
        }
        if terminalPanel.surface.sendInputResult(data) == .sent {
            terminalPanel.surface.forceRefresh(reason: "share.guestInput")
            return true
        }
        return false
    }

    /// Routes subscription demand only to a current terminal pane in the one
    /// shared workspace. A zero count may clear a pane that just disappeared.
    private func routeGuestSub(ws: String, pane: String, count: Int) -> Bool {
        guard let workspaceID = UUID(uuidString: ws),
              sharedWorkspaceIDs == [workspaceID],
              let paneID = UUID(uuidString: pane) else {
            return false
        }
        if count <= 0 {
            streamer.setSubscriberCount(ws: ws, pane: pane, count: 0)
            return true
        }
        guard let tabManager,
              let workspace = sharedWorkspace(in: tabManager),
              workspace.id == workspaceID,
              workspace.terminalPanel(for: paneID) != nil else {
            return false
        }
        streamer.setSubscriberCount(ws: ws, pane: pane, count: count)
        return true
    }

    // MARK: - Cursor overlay wiring

    private func wireCursorOverlay() {
        cursorOverlay.resolvePaneView = { [weak self] ws, pane in
            self?.paneContentView(ws: ws, pane: pane)
        }
        cursorOverlay.isWorkspaceVisible = { [weak self] ws in
            guard let self, let tabManager = self.tabManager,
                  let wsUUID = UUID(uuidString: ws) else { return false }
            return self.sharedWorkspaceIDs.contains(wsUUID)
                && tabManager.selectedTabId == wsUUID
        }
        cursorOverlay.sendHostCursor = { [weak self] pos in
            self?.socket?.send(.cursor(pos))
        }
        cursorOverlay.hostCursorPosition = { [weak self] event in
            self?.hostCursorPosition(for: event)
        }
        cursorOverlay.installMouseMonitor()
    }

    private func paneContentView(ws: String, pane: String) -> NSView? {
        guard let tabManager,
              let wsUUID = UUID(uuidString: ws),
              let paneUUID = UUID(uuidString: pane),
              let workspace = sharedWorkspace(in: tabManager),
              workspace.id == wsUUID,
              let terminalPanel = workspace.terminalPanel(for: paneUUID) else {
            return nil
        }
        return terminalPanel.hostedView
    }

    /// Maps a host mouse event to a pane-relative position over the visible
    /// shared workspace's terminal panes.
    private func hostCursorPosition(for event: NSEvent) -> ShareCursorPos? {
        guard let tabManager,
              let selectedID = tabManager.selectedTabId,
              sharedWorkspaceIDs.contains(selectedID),
              let workspace = tabManager.tabs.first(where: { $0.id == selectedID }),
              let eventWindow = event.window else {
            return nil
        }
        for panelID in workspace.orderedPanelIds {
            guard let terminalPanel = workspace.terminalPanel(for: panelID) else { continue }
            let paneView = terminalPanel.hostedView
            guard paneView.window === eventWindow else { continue }
            let local = paneView.convert(event.locationInWindow, from: nil)
            guard paneView.bounds.contains(local), paneView.bounds.width > 0, paneView.bounds.height > 0 else {
                continue
            }
            let x = (local.x - paneView.bounds.minX) / paneView.bounds.width
            let yFromTop = paneView.isFlipped
                ? (local.y - paneView.bounds.minY) / paneView.bounds.height
                : (paneView.bounds.maxY - local.y) / paneView.bounds.height
            return ShareCursorPos(
                ws: selectedID.uuidString,
                pane: terminalPanel.surface.id.uuidString,
                x: Double(x),
                y: Double(yFromTop)
            )
        }
        return nil
    }

    isolated deinit {
        startTask?.cancel()
        socketEventTask?.cancel()
        socketStopTask?.cancel()
        streamer.stop()
        cursorOverlay.teardown()
        globalCancellables.removeAll()
        perWorkspaceCancellables.removeAll()
        chatWindow?.close()
    }
}
