import AppKit
import Bonsplit
import Combine
import Foundation
import OSLog

private let workspaceShareLog = Logger(subsystem: "dev.cmux", category: "workspace-share")

/// Hosts one read-only multiplayer share of a workspace
/// (plans/feat-multiplayer-share/DESIGN.md). Owns the session lifecycle:
/// create over HTTPS, host WebSocket to the ShareSession Durable Object,
/// per-surface PTY streaming, layout/textbox mirroring, join approvals, and
/// the remote-cursor overlay.
@MainActor
final class WorkspaceShareService: ObservableObject {
    static let shared = WorkspaceShareService()

    enum State: Equatable {
        case idle
        case starting
        case active(shareId: String, url: URL)
    }

    @Published private(set) var state: State = .idle
    private(set) weak var sharedWorkspace: Workspace?

    private var socket: WorkspaceShareSocket?
    private var receiveTask: Task<Void, Never>?
    private var termTasks: [UUID: Task<Void, Never>] = [:]
    private var textBoxObservations: [UUID: AnyCancellable] = [:]
    private var layoutObserver: NSObjectProtocol?
    private var cursorMonitor: Any?
    private var lastCursorSend: ContinuousClock.Instant?
    private var lastSentWorkspace: ShareWorkspace?
    private let overlay = WorkspaceShareOverlayController()

    var isSharing: Bool {
        if case .active = state { return true }
        return false
    }

    func isSharing(workspace: Workspace) -> Bool {
        isSharing && sharedWorkspace === workspace
    }

    // MARK: - Start / stop

    /// Creates a session, connects the host lane, and starts streaming.
    /// Returns the share URL (already copied to the pasteboard).
    func startSharing(workspace: Workspace) async throws -> URL {
        guard case .idle = state else {
            if case .active(_, let url) = state { return url }
            throw ShareStartError.alreadyStarting
        }
        state = .starting
        do {
            let created = try await createSession(title: workspace.title)
            let base = WorkspaceShareEndpoints.serviceBaseURL()
            guard let socketURL = WorkspaceShareEndpoints.hostSocketURL(
                base: base, shareId: created.shareId, hostToken: created.hostToken
            ) else {
                throw ShareStartError.badServiceURL
            }
            let url = created.url.flatMap(URL.init(string:))
                ?? WorkspaceShareEndpoints.sharePageURL(shareId: created.shareId)

            let socket = WorkspaceShareSocket(url: socketURL)
            socket.start()
            self.socket = socket
            sharedWorkspace = workspace
            state = .active(shareId: created.shareId, url: url)

            startReceiveLoop(socket: socket)
            startLayoutMirror(workspace: workspace)
            startCursorMonitor(workspace: workspace)
            overlay.attach(to: workspaceWindow(for: workspace), workspace: workspace)
            syncStreams(workspace: workspace)
            sendLayout(workspace: workspace, force: true)

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            workspaceShareLog.info("share started id=\(created.shareId, privacy: .public)")
            return url
        } catch {
            state = .idle
            sharedWorkspace = nil
            socket?.close(sendEnd: false)
            socket = nil
            throw error
        }
    }

    func stopSharing() {
        guard state != .idle else { return }
        socket?.close(sendEnd: true)
        socket = nil
        receiveTask?.cancel()
        receiveTask = nil
        for task in termTasks.values { task.cancel() }
        termTasks.removeAll()
        textBoxObservations.removeAll()
        if let layoutObserver {
            NotificationCenter.default.removeObserver(layoutObserver)
            self.layoutObserver = nil
        }
        if let cursorMonitor {
            NSEvent.removeMonitor(cursorMonitor)
            self.cursorMonitor = nil
        }
        overlay.detach()
        lastSentWorkspace = nil
        sharedWorkspace = nil
        state = .idle
        workspaceShareLog.info("share stopped")
    }

    enum ShareStartError: Error, Equatable {
        case alreadyStarting
        case badServiceURL
        case notSignedIn
        case createFailed(status: Int)
    }

    static func startErrorDescription(_ error: Error) -> String {
        switch error {
        case ShareStartError.notSignedIn:
            return String(
                localized: "share.error.notSignedIn",
                defaultValue: "Sign in to cmux to share a workspace."
            )
        case ShareStartError.alreadyStarting:
            return String(
                localized: "share.error.alreadyStarting",
                defaultValue: "A share session is already starting."
            )
        case ShareStartError.badServiceURL:
            return String(
                localized: "share.error.badServiceURL",
                defaultValue: "The share service URL is invalid."
            )
        case ShareStartError.createFailed(let status):
            return String(
                format: String(
                    localized: "share.error.createFailed",
                    defaultValue: "The share service rejected the request (status %d)."
                ),
                status
            )
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Create

    private func createSession(title: String) async throws -> ShareCreateResponse {
        guard let coordinator = AppDelegate.shared?.auth?.coordinator else {
            throw ShareStartError.notSignedIn
        }
        let token: String
        do {
            token = try await coordinator.accessToken()
        } catch {
            throw ShareStartError.notSignedIn
        }
        var request = URLRequest(url: WorkspaceShareEndpoints.createURL(
            base: WorkspaceShareEndpoints.serviceBaseURL()
        ))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["title": title])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ShareStartError.createFailed(
                status: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
        return try JSONDecoder().decode(ShareCreateResponse.self, from: data)
    }

    // MARK: - Inbound

    private func startReceiveLoop(socket: WorkspaceShareSocket) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                let frame: ShareInboundFrame
                do {
                    frame = try await socket.receive()
                } catch {
                    guard let self, self.socket === socket else { return }
                    workspaceShareLog.warning("host socket closed: \(error, privacy: .public)")
                    self.stopSharing()
                    return
                }
                guard let self, self.socket === socket else { return }
                self.handleInbound(frame)
            }
        }
    }

    private func handleInbound(_ frame: ShareInboundFrame) {
        switch frame {
        case .joinRequest(let requestId, let email, let name):
            presentJoinRequest(requestId: requestId, email: email, name: name)
        case .syncRequest(let participantId):
            guard let workspace = sharedWorkspace else { return }
            let snapshot = WorkspaceShareLayoutBuilder.makeWorkspace(
                workspace: workspace, includeReplay: true
            )
            socket?.send(.snapshot(to: participantId, workspace: snapshot))
        case .cursor(let participantId, let x, let y):
            overlay.updateRemoteCursor(participantId: participantId, x: x, y: y)
        case .chat(let participantId, _, let text, let x, let y):
            overlay.showChat(participantId: participantId, text: text, x: x, y: y)
        case .presence(let participants):
            overlay.updateParticipants(participants)
        case .ended:
            stopSharing()
        case .unknown(let type):
            workspaceShareLog.debug("ignoring unknown frame type=\(type, privacy: .public)")
        }
    }

    private func presentJoinRequest(requestId: String, email: String, name: String) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "share.joinRequest.title",
            defaultValue: "Workspace share join request"
        )
        let who = name.isEmpty ? email : "\(name) (\(email))"
        alert.informativeText = String(
            format: String(
                localized: "share.joinRequest.message",
                defaultValue: "%@ wants to view this workspace."
            ),
            who
        )
        alert.addButton(withTitle: String(localized: "share.joinRequest.allow", defaultValue: "Allow"))
        alert.addButton(withTitle: String(localized: "share.joinRequest.deny", defaultValue: "Deny"))
        let allow = alert.runCmuxModal() == .alertFirstButtonReturn
        socket?.send(.joinResponse(requestId: requestId, allow: allow))
    }

    // MARK: - Layout mirror

    private func startLayoutMirror(workspace: Workspace) {
        layoutObserver = NotificationCenter.default.addObserver(
            forName: .workspacePaneGeometryDidChange,
            object: workspace,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let workspace = self.sharedWorkspace else { return }
                self.syncStreams(workspace: workspace)
                self.sendLayout(workspace: workspace, force: false)
            }
        }
    }

    private func sendLayout(workspace: Workspace, force: Bool) {
        let shape = WorkspaceShareLayoutBuilder.makeWorkspace(workspace: workspace, includeReplay: false)
        guard force || shape != lastSentWorkspace else { return }
        lastSentWorkspace = shape
        socket?.send(.layout(workspace: shape))
        for pane in shape.panes {
            if let surfaceIdString = pane.surfaceId, let cols = pane.cols, let rows = pane.rows,
               UUID(uuidString: surfaceIdString) != nil {
                socket?.send(.termResize(surfaceId: surfaceIdString, cols: cols, rows: rows))
            }
        }
    }

    // MARK: - Terminal streaming

    /// Reconciles per-surface PTY streaming tasks and textbox mirrors with the
    /// panels currently in the shared workspace.
    private func syncStreams(workspace: Workspace) {
        let terminalPanels = workspace.panels.values.compactMap { $0 as? TerminalPanel }
        let liveIds = Set(terminalPanels.map(\.id))

        for (id, task) in termTasks where !liveIds.contains(id) {
            task.cancel()
            termTasks[id] = nil
            textBoxObservations[id] = nil
        }
        for panel in terminalPanels {
            if termTasks[panel.id] == nil {
                termTasks[panel.id] = makeTermStreamTask(surfaceId: panel.id)
            }
            if textBoxObservations[panel.id] == nil {
                textBoxObservations[panel.id] = makeTextBoxObservation(panel: panel, workspace: workspace)
            }
        }
    }

    private func makeTermStreamTask(surfaceId: UUID) -> Task<Void, Never> {
        Task { [weak self] in
            // `outputUpdates` ends the stream on slow-consumer drop; loop to
            // re-subscribe. Viewers detect the seq gap and re-request a
            // snapshot through the DO's `sync_request` path.
            while !Task.isCancelled {
                guard let self, let socket = self.socket else { return }
                let updates = MobileTerminalByteTee.shared.outputUpdates(surfaceID: surfaceId)
                for await chunk in updates {
                    guard !Task.isCancelled else { return }
                    socket.send(.term(
                        surfaceId: surfaceId.uuidString,
                        seq: chunk.sequence,
                        dataB64: chunk.data.base64EncodedString()
                    ))
                }
                guard !Task.isCancelled else { return }
                // Stream ended (drop or surface teardown). Yield before
                // re-subscribing so a torn-down surface doesn't spin.
                await Task.yield()
                if MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceId) == nil {
                    return
                }
            }
        }
    }

    private func makeTextBoxObservation(panel: TerminalPanel, workspace: Workspace) -> AnyCancellable {
        // First pass mirrors text content only; selection tracking is a
        // follow-up (selStart/selEnd pinned to end of text).
        panel.$textBoxContent
            .removeDuplicates()
            .sink { [weak self, weak panel, weak workspace] text in
                guard let self, let panel, let workspace,
                      let paneId = Self.paneId(forPanelId: panel.id, workspace: workspace) else { return }
                self.socket?.send(.textbox(
                    paneId: paneId,
                    text: text,
                    selStart: text.count,
                    selEnd: text.count,
                    active: !text.isEmpty
                ))
            }
    }

    private static func paneId(forPanelId panelId: UUID, workspace: Workspace) -> String? {
        let snapshot = workspace.bonsplitController.layoutSnapshot()
        for geometry in snapshot.panes {
            guard let selected = geometry.selectedTabId,
                  let selectedUUID = UUID(uuidString: selected),
                  workspace.panelIdFromSurfaceId(TabID(uuid: selectedUUID)) == panelId else { continue }
            return geometry.paneId
        }
        return nil
    }

    // MARK: - Host cursor

    private func startCursorMonitor(workspace: Workspace) {
        cursorMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouseEvent(event)
            }
            return event
        }
        workspaceWindow(for: workspace)?.acceptsMouseMovedEvents = true
    }

    private func handleMouseEvent(_ event: NSEvent) {
        guard let workspace = sharedWorkspace,
              let window = event.window,
              window === workspaceWindow(for: workspace) else { return }
        // Throttle to ~30/s (the DO also rate limits per sender).
        let now = ContinuousClock.now
        if let last = lastCursorSend, now - last < .milliseconds(33) { return }

        let snapshot = workspace.bonsplitController.layoutSnapshot()
        let container = CGRect(
            x: snapshot.containerFrame.x,
            y: snapshot.containerFrame.y,
            width: snapshot.containerFrame.width,
            height: snapshot.containerFrame.height
        )
        guard let contentView = window.contentView else { return }
        // bonsplit's container frame is SwiftUI `.global` (top-left origin in
        // the window's content); NSEvent locations are bottom-left origin.
        let location = event.locationInWindow
        let topLeftPoint = CGPoint(x: location.x, y: contentView.bounds.height - location.y)
        guard let normalized = WorkspaceShareLayoutMath.normalizedPoint(topLeftPoint, container: container) else {
            return
        }
        lastCursorSend = now
        socket?.send(.cursor(x: normalized.x, y: normalized.y))
    }

    private func workspaceWindow(for workspace: Workspace) -> NSWindow? {
        // The shared workspace renders in a cmux main window; use the window
        // hosting a live terminal view when available, else the key/main window.
        for panel in workspace.panels.values {
            if let terminal = panel as? TerminalPanel,
               let window = terminal.textBoxInputView?.window {
                return window
            }
        }
        return NSApp.cmuxMainWindowForModalPresentation()
    }
}
