import AppKit
import Combine
import Foundation

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
}

/// One row in the chat window's workspace-sharing section.
struct ShareWorkspaceRow: Identifiable, Equatable {
    let id: UUID
    var title: String
    var isShared: Bool
}

/// Orchestrates one multiplayer share session: session creation, the DO
/// socket, layout observation, grid streaming, guest input, moderation, and
/// cursor overlays. Singleton, main-actor; all mutation happens here.
@MainActor
final class ShareSessionController: ObservableObject {
    static let shared = ShareSessionController()

    enum Status: Equatable {
        case idle
        case starting
        case active
        case reconnecting
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var shareUrl: String?
    @Published private(set) var code: String?
    @Published private(set) var participants: [ShareParticipant] = []
    @Published private(set) var feed: [ShareFeedItem] = []
    @Published private(set) var workspaceRows: [ShareWorkspaceRow] = []
    @Published private(set) var lastErrorText: String?

    var isSharing: Bool { status != .idle }

    private(set) var sharedWorkspaceIDs: Set<UUID> = []
    private(set) weak var tabManager: TabManager?
    private var api: ShareSessionAPI?
    private(set) var socket: ShareSocket?
    let streamer = ShareGridStreamer()
    let pixelStreamer = SharePixelStreamer()
    let composerSync = ShareComposerSync()
    let browserInput = ShareBrowserInputApplier()
    var composerHookedPanelIDs = Set<UUID>()
    private let cursorOverlay = ShareCursorOverlayController()
    private lazy var chatWindow = ShareChatWindowController(controller: self)
    private var startTask: Task<Void, Never>?
    private var globalCancellables = Set<AnyCancellable>()
    private var perWorkspaceCancellables: [UUID: AnyCancellable] = [:]
    private var lastSentShared: [ShareSharedWorkspace] = []
    private var lastSentLayouts: [String: ShareWorkspaceLayout] = [:]
    private var lastSentFocusWs: String??
    private static let layoutThrottleMilliseconds = 100

    private init() {}

    // MARK: - Lifecycle

    func startSharing() {
        if isSharing {
            chatWindow.show()
            return
        }
        guard let tabManager = AppDelegate.shared?.tabManager else {
            lastErrorText = String(
                localized: "share.error.noWorkspaceContext",
                defaultValue: "Sharing is unavailable: no workspace window is open."
            )
            return
        }
        guard let coordinator = AppDelegate.shared?.auth?.coordinator else {
            lastErrorText = String(
                localized: "share.error.notSignedIn",
                defaultValue: "Sign in to cmux to share workspaces."
            )
            return
        }
        self.tabManager = tabManager
        lastErrorText = nil
        status = .starting
        let api = ShareSessionAPI(auth: coordinator)
        self.api = api
        startTask = Task { @MainActor [weak self] in
            do {
                let created = try await api.createSession()
                guard let self, self.status == .starting else { return }
                self.activate(created: created, api: api)
            } catch {
                guard let self, self.status == .starting else { return }
                self.status = .idle
                // User-facing copy stays localized and generic; the detail
                // goes to the debug log only.
                cmuxDebugLog("share.start failed: \(String(describing: error))")
                self.lastErrorText = String(
                    localized: "share.error.startFailed",
                    defaultValue: "Couldn't start sharing. Check your connection and try again."
                )
            }
        }
    }

    func stopSharing() {
        guard isSharing else { return }
        socket?.send(.end)
        teardownSession()
    }

    private func activate(created: ShareSessionCreateResult, api: ShareSessionAPI) {
        guard let tabManager else {
            status = .idle
            return
        }
        code = created.code
        shareUrl = created.shareUrl
        copyShareLink()
        sharedWorkspaceIDs = Set(tabManager.tabs.map(\.id))
        wireCursorOverlay()
        streamer.sendBinary = { [weak self] data in
            self?.socket?.send(data: data)
        }
        streamer.start()
        wirePaneStreamsAndComposer()
        attachLayoutObservation(tabManager: tabManager)

        let code = created.code
        let socket = ShareSocket(
            endpoint: ShareSocket.Endpoint(wsUrl: created.wsUrl, token: created.token),
            refresh: {
                let refreshed = try await api.hostToken(code: code)
                return ShareSocket.Endpoint(wsUrl: refreshed.wsUrl, token: refreshed.token)
            }
        )
        socket.onOpen = { [weak self] in
            guard let self, self.isSharing else { return }
            self.status = .active
            self.sendHello()
        }
        socket.onConnectionStateChange = { [weak self] connected in
            guard let self, self.isSharing else { return }
            if !connected { self.status = .reconnecting }
        }
        socket.onText = { [weak self] text in
            self?.handleServerText(text)
        }
        self.socket = socket
        socket.start()

        syncWorkspaceRows()
        chatWindow.show()
    }

    private func teardownSession() {
        startTask?.cancel()
        startTask = nil
        socket?.stop()
        socket = nil
        streamer.stop()
        streamer.sendBinary = nil
        pixelStreamer.stopAll()
        pixelStreamer.sendBinary = nil
        composerSync.reset()
        browserInput.reset()
        uninstallComposerHooks()
        cursorOverlay.teardown()
        globalCancellables.removeAll()
        perWorkspaceCancellables.removeAll()
        chatWindow.close()
        status = .idle
        code = nil
        shareUrl = nil
        participants = []
        feed = []
        workspaceRows = []
        sharedWorkspaceIDs = []
        lastSentShared = []
        lastSentLayouts = [:]
        lastSentFocusWs = nil
        api = nil
    }

    // MARK: - Chat window actions

    func copyShareLink() {
        guard let shareUrl else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(shareUrl, forType: .string)
    }

    func setWorkspaceShared(id: UUID, isShared: Bool) {
        guard isSharing else { return }
        if isShared {
            sharedWorkspaceIDs.insert(id)
        } else {
            sharedWorkspaceIDs.remove(id)
        }
        syncSharedAndLayouts()
    }

    func sendChat(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The DO echoes chat back to every active connection (including the
        // sender), so the echo is the single append path.
        socket?.send(.chat(text: trimmed, bubble: nil))
    }

    func approve(user: String, role: ShareRole) {
        socket?.send(.approve(user: user, role: role))
        resolveAccessRequest(user: user, resolution: role == .editor ? .approvedEditor : .approvedViewer)
    }

    func deny(user: String) {
        socket?.send(.deny(user: user))
        resolveAccessRequest(user: user, resolution: .denied)
    }

    func kick(user: String) {
        socket?.send(.kick(user: user))
        cursorOverlay.removeRemoteUser(user)
        composerSync.removeParticipantCarets(user: user)
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

    private func sendHello() {
        guard let tabManager else { return }
        let sharedWorkspaces = liveSharedWorkspaces(tabManager: tabManager)
        let shared = sharedWorkspaces.map(ShareLayoutSerializer.sharedWorkspace(for:))
        let layouts = sharedWorkspaces.map(ShareLayoutSerializer.layout(for:))
        lastSentShared = shared
        lastSentLayouts = Dictionary(uniqueKeysWithValues: layouts.map { ($0.ws, $0) })
        lastSentFocusWs = nil
        socket?.send(.hello(shared: shared, layouts: layouts))
        sendFocusIfChanged()
    }

    private func liveSharedWorkspaces(tabManager: TabManager) -> [Workspace] {
        tabManager.tabs.filter { sharedWorkspaceIDs.contains($0.id) }
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
        let currentIDs = Set(tabs.map(\.id))
        for id in perWorkspaceCancellables.keys where !currentIDs.contains(id) {
            perWorkspaceCancellables.removeValue(forKey: id)
        }
        for workspace in tabs where perWorkspaceCancellables[workspace.id] == nil {
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
        let liveIDs = Set(tabManager.tabs.map(\.id))
        sharedWorkspaceIDs.formIntersection(liveIDs)
        syncWorkspaceRows()

        let sharedWorkspaces = liveSharedWorkspaces(tabManager: tabManager)
        let shared = sharedWorkspaces.map(ShareLayoutSerializer.sharedWorkspace(for:))
        if shared != lastSentShared {
            lastSentShared = shared
            socket?.send(.shared(shared))
        }
        var nextLayouts: [String: ShareWorkspaceLayout] = [:]
        for workspace in sharedWorkspaces {
            let layout = ShareLayoutSerializer.layout(for: workspace)
            nextLayouts[layout.ws] = layout
            if lastSentLayouts[layout.ws] != layout {
                socket?.send(.layout(layout))
            }
        }
        lastSentLayouts = nextLayouts
        syncComposerHooks(sharedWorkspaces: sharedWorkspaces)
        cursorOverlay.refreshAll()
        sendFocusIfChanged()
    }

    private func syncWorkspaceRows() {
        guard let tabManager else { return }
        let rows = tabManager.tabs.map { workspace in
            ShareWorkspaceRow(
                id: workspace.id,
                title: workspace.title,
                isShared: sharedWorkspaceIDs.contains(workspace.id)
            )
        }
        if rows != workspaceRows {
            workspaceRows = rows
        }
    }

    private func sendFocusIfChanged() {
        guard isSharing, let tabManager else { return }
        let focusWs: String? = tabManager.selectedTabId
            .flatMap { sharedWorkspaceIDs.contains($0) ? $0.uuidString : nil }
        if lastSentFocusWs != .some(focusWs) {
            lastSentFocusWs = .some(focusWs)
            socket?.send(.focus(ws: focusWs))
        }
    }

    // MARK: - Inbound

    private func handleServerText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(ShareServerMessage.self, from: data) else {
            return
        }
        switch message {
        case .sessionState(let snapshot):
            participants = snapshot.participants
            rebuildFeed(chat: snapshot.chat)
        case .accessRequest(let user, let email):
            appendAccessRequest(user: user, email: email)
        case .presence(let updated):
            participants = updated
            pruneCursors()
        case .cursor(let user, let pos):
            guard let participant = participant(user) else { return }
            cursorOverlay.updateRemoteCursor(
                user: user,
                email: participant.email,
                colorIndex: participant.color,
                pos: pos
            )
        case .chat(let message):
            appendChat(message)
        case .guestInput(let user, let ws, let pane, let data):
            applyGuestInput(user: user, ws: ws, pane: pane, data: data)
        case .guestSub(let ws, let pane, let count):
            routeGuestSub(ws: ws, pane: pane, count: count)
        case .guestCompose(let user, let field, let rev, let ops, let caret):
            applyGuestCompose(user: user, field: field, rev: rev, ops: ops, caret: caret)
        case .guestPointer(let pointer):
            applyGuestPointer(pointer)
        case .guestWebKey(let key):
            applyGuestWebKey(key)
        case .resync:
            sendHello()
            streamer.resendFullFrames()
            pixelStreamer.requestKeyframes()
        case .sessionEnded:
            teardownSession()
        case .error(let code, let message):
            cmuxDebugLog("share.server error code=\(code) message=\(message)")
            lastErrorText = String(
                localized: "share.error.sessionError",
                defaultValue: "The share session hit an error. Reconnecting…"
            )
        case .unknown:
            break
        }
    }

    func participant(_ user: String) -> ShareParticipant? {
        participants.first { $0.user == user }
    }

    private func pruneCursors() {
        let connected = Set(participants.filter(\.connected).map(\.user))
        for row in participants where !connected.contains(row.user) {
            cursorOverlay.removeRemoteUser(row.user)
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
        items.append(contentsOf: pendingRequests)
        feed = items
    }

    private func appendChat(_ message: ShareChatMessage) {
        guard !feed.contains(where: { $0.id == message.id }) else { return }
        feed.append(feedItem(for: message))
    }

    private func feedItem(for message: ShareChatMessage) -> ShareFeedItem {
        let sender = participant(message.user)
        return ShareFeedItem(
            id: message.id,
            kind: .chat(
                user: message.user,
                email: sender?.email ?? message.user,
                colorIndex: sender?.color ?? 0,
                text: message.text,
                hasBubble: message.bubble != nil
            )
        )
    }

    private func appendAccessRequest(user: String, email: String) {
        // A repeat request from the same still-pending user collapses into one
        // actionable item.
        let hasPending = feed.contains { item in
            if case .accessRequest(let requestUser, _, .none) = item.kind {
                return requestUser == user
            }
            return false
        }
        guard !hasPending else { return }
        feed.append(ShareFeedItem(
            id: "access-request:\(user):\(feed.count)",
            kind: .accessRequest(user: user, email: email, resolution: nil)
        ))
    }

    /// Applies guest terminal input. The host is the only input authority:
    /// the workspace must be in the shared set and the sender's locally-known
    /// role must be `editor`, regardless of what the DO forwarded.
    private func applyGuestInput(user: String, ws: String, pane: String, data: String) {
        guard !data.isEmpty,
              let wsUUID = UUID(uuidString: ws),
              sharedWorkspaceIDs.contains(wsUUID),
              participant(user)?.role == .editor,
              let tabManager,
              let workspace = tabManager.tabs.first(where: { $0.id == wsUUID }),
              let paneUUID = UUID(uuidString: pane),
              let terminalPanel = workspace.terminalPanel(for: paneUUID) else {
            return
        }
        if terminalPanel.surface.sendInputResult(data) == .sent {
            terminalPanel.surface.forceRefresh(reason: "share.guestInput")
        }
    }

    // MARK: - Cursor overlay wiring

    private func wireCursorOverlay() {
        cursorOverlay.resolvePaneView = { [weak self] ws, pane in
            self?.paneContentView(ws: ws, pane: pane)
        }
        cursorOverlay.isWorkspaceVisible = { [weak self] ws in
            guard let self, let tabManager = self.tabManager,
                  let wsUUID = UUID(uuidString: ws) else { return false }
            return tabManager.selectedTabId == wsUUID
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
              let workspace = tabManager.tabs.first(where: { $0.id == wsUUID }),
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
}
