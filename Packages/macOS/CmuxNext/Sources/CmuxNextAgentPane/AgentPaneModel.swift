public import Foundation
public import Observation

/// One agent pane's host-side state: which acpmux session it shows. The
/// session, its transcript and every chat action live in acpmux and the
/// page; this only answers the page's host requests.
@Observable
public final class AgentPaneModel {
    /// The session the page last reported, nil for a new chat that has not
    /// sent its first prompt.
    public private(set) var sessionId: String?
    /// Page projection of its single session-host Git capability read, never an authorization grant.
    public private(set) var checkpointAvailable = false
    @ObservationIgnored public var onCheckpointAvailability: ((Bool) -> Void)?
    /// The page drew its first frame after the handshake (`pane.painted`), the
    /// first that shows what it is. Until then its pane keeps what it showed.
    public internal(set) var hasPainted = false
    @ObservationIgnored var paintWaiters: [() -> Void] = []

    /// Called when the page switches to or creates a session, so the App can
    /// keep it with the tab.
    @ObservationIgnored public var onSessionChange: ((String) -> Void)?
    /// Reports each settled scroll and returns the native display settings to the page.
    @ObservationIgnored public var onFramePacing: (([Double]) -> [String: Any])?
    /// Applies the page's adaptive rendering decision.
    @ObservationIgnored public var onRenderRate: ((Bool) -> Void)?
    /// The new tab page this pane shows until it has a session, nil for a
    /// plain chat. Cleared once the page reports a session.
    public private(set) var newTab: AgentPaneNewTab?
    /// The new tab page chose a terminal or browser (`tab.open`).
    @ObservationIgnored public var onOpenTab: ((AgentPaneOpenTab) -> Void)?
    /// What the user typed after `!` so far (`tab.typeAhead`).
    @ObservationIgnored public var onTypeAhead: ((String) -> Void)?
    /// The agent picked on the new tab screen, to remember (`newTab.remember`).
    @ObservationIgnored public var onRememberNewTab: ((String) -> Void)?
    /// The location bar picked an open tab or workspace (`tab.jump`).
    @ObservationIgnored public var onJump: ((AgentPaneJumpTarget, String) -> Void)?
    /// The new tab page asked to change a kind's shortcut.
    @ObservationIgnored public var onEditShortcut: ((AgentPaneTabKind) -> Void)?
    /// The new tab page's "default: X" toggle (`tab.setDefaultKind`).
    @ObservationIgnored public var onSetDefaultKind: ((String) -> Void)?
    /// Runs an app action requested by an empty-state or new-tab control.
    @ObservationIgnored public var onRunAction: ((String) -> Void)?
    /// Resolves the explicit Browse… fallback in the project picker.
    @ObservationIgnored public var onBrowseProject: (() async -> String?)?
    /// Returns bounded project paths for the picker, optionally filtered by query.
    @ObservationIgnored public var onListProjects: ((String?) async -> [String])?
    /// Opens onboarding's existing project and agent-history import flow.
    @ObservationIgnored public var onImportAndSync: (() -> Void)?
    /// Runs an action advertised by the host's omnibar.
    @ObservationIgnored public var onAppAction: ((String) -> Void)?
    /// The chat header's tab actions and tab state (``AgentPaneHeaderHooks``).
    @ObservationIgnored public var header: AgentPaneHeaderHooks?
    /// Gets the composer's dictation requests (the pane's mic).
    @ObservationIgnored public var onDictation: ((AgentPaneDictationCommand) -> Void)?
    /// Opens a changed file the page names; false when it could not.
    @ObservationIgnored public var onOpenFile: (@MainActor (URL, AgentPaneFileTarget) async -> Bool)?
    /// Opens a turn's local web page in a browser tab beside the agent;
    /// false when it could not.
    @ObservationIgnored public var onOpenPreview: (@MainActor (URL) -> Bool)?
    /// The quick panel's page asked to hide the panel (`quick.dismiss`).
    @ObservationIgnored public var onQuickDismiss: (() -> Void)?
    /// The quick panel's page asked to open its chat in the main window
    /// (`quick.openInWindow`). Gets the chat's session, nil before the
    /// first prompt.
    @ObservationIgnored public var onQuickOpenInWindow: ((String?) -> Void)?
    /// This build's URL scheme, handed to the page with every handshake so
    /// the links it copies open in this build; nil leaves it out.
    @ObservationIgnored public var linkScheme: String?
    /// Set for a tab a `cmux://session/<id>` link opened: the handshake asks
    /// the page to refuse a session the daemon does not have rather than
    /// show the most recent one. Cleared once the page reports a session.
    @ObservationIgnored public var sessionMustExist = false
    /// A `#turn-<turnId>` link's turn the page has not been handed yet; the
    /// next handshake carries it (`revealTurn`) and clears it.
    @ObservationIgnored public var pendingRevealTurn: String?
    /// Whether the page has asked for a handshake, so its bridge is up and
    /// a turn can be revealed through it directly.
    @ObservationIgnored public private(set) var hasHandshake = false
    /// Runs a git read on the session host and returns its JSON result.
    /// Throws an ``AgentPaneGitFailure`` saying who failed; any other error
    /// reaches the page as `native.failed`.
    @ObservationIgnored public var onGit: (@MainActor (AgentPaneGitRequest) async throws -> Data)?

    /// Whether this host supports converting a fresh chat without a chooser page.
    @ObservationIgnored private let allowsTabConversion: Bool
    /// The host's acpmux socket for this pane (in the app the page never holds one).
    @ObservationIgnored public let transport: AgentPaneTransport
    /// Shell mode's commands (`shell.run`, `shell.read`, `shell.stop`).
    @ObservationIgnored public let shell = AgentPaneShell()
    /// The last handshake's connection, until the page opens it: used once, so the LocalApp
    /// token is never kept beyond one handshake.
    @ObservationIgnored private var pendingConnection: AcpmuxConnection?
    /// The folders of this pane's workspace the App knows (its local tabs' folders). With the
    /// handshake's cwd and the new tab page's folders they are the roots every `cwd` or `path`
    /// the page sends must be under (``AcpmuxPathPolicy``).
    @ObservationIgnored public var workspaceRoots: (@MainActor () -> [String])?
    @ObservationIgnored private var handshakeCwd: String?

    @ObservationIgnored private let host: any AgentPaneHostProviding
    /// What a new chat inherits from the tab it was opened from.
    @ObservationIgnored private let seed: AgentPaneSeedSource?

    public init(
        host: any AgentPaneHostProviding,
        sessionId: String? = nil,
        seed: AgentPaneSeedSource? = nil,
        newTab: AgentPaneNewTab? = nil,
        allowsTabConversion: Bool = false,
        transport: AgentPaneTransport = AgentPaneTransport()
    ) {
        self.allowsTabConversion = allowsTabConversion
        self.host = host
        self.transport = transport
        self.sessionId = sessionId
        self.seed = seed
        self.newTab = sessionId == nil ? newTab : nil
        transport.roots = { [weak self] in self?.roots() ?? [] }
        transport.gestureRoots = { [weak self] in self?.gestureRoots() ?? [] }
        transport.primaryRoot = { [weak self] in self?.primaryRoot() }
        transport.requestRoot = { [weak self] folder, answer in
            guard let onRequestRoot = self?.onRequestRoot else { return answer(false) }
            onRequestRoot(folder, answer)
        }
        if let sessionId { transport.sessions.add(sessionId) }
        transport.requestModeConfirmation = { [weak self] asked, answer in
            guard let onConfirmMode = self?.onConfirmMode else { return answer(false) }
            onConfirmMode(asked, answer)
        }
    }

    /// Asks the user to confirm a mode that does not ask before it acts (the view's native sheet).
    @ObservationIgnored public var onConfirmMode: (@MainActor (_ asked: AgentPaneModeConfirmation, _ answer: @escaping @MainActor (Bool) -> Void) -> Void)?

    /// Asks the user to add a folder the page named outside every root (the view's native sheet).
    @ObservationIgnored public var onRequestRoot: (@MainActor (_ folder: String, _ answer: @escaping @MainActor (Bool) -> Void) -> Void)?

    /// The host's own roots for ``AcpmuxPathPolicy``: the workspace's local tab folders, the
    /// handshake's cwd and the new tab page's cwd.
    func roots() -> [String] {
        var roots = workspaceRoots?() ?? []
        if let handshakeCwd { roots.append(handshakeCwd) }
        if let cwd = newTab?.cwd { roots.append(cwd) }
        return roots
    }

    /// The new tab page's project scan and open folders: roots only when the user picks one.
    func gestureRoots() -> [String] {
        guard let newTab else { return [] }
        return newTab.projects + newTab.omnibar.folders
    }

    /// The pane's workspace root: what a `session/new` without a cwd gets.
    func primaryRoot() -> String? {
        handshakeCwd ?? workspaceRoots?().first ?? newTab?.cwd
    }

    /// Cmd-T adopted this prewarmed new tab page: `page` is the context of
    /// the tab it became (plans/cmux-next/new-tab.md section 2.2). A page that
    /// already became a chat keeps its chat.
    /// User input reached the page, or it ran any op beyond boot (the
    /// handshake, frame pacing, render rate, capabilities). A touched page is
    /// never recycled into the prewarm pool (coordinator: strictly untouched).
    public private(set) var userTouched = false
    /// The request that first touched the page, its case name only (diagnostics).
    public private(set) var touchedBy: String?

    public func adoptNewTab(_ page: AgentPaneNewTab) {
        guard newTab != nil else { return }
        newTab = page
    }

    /// A new workspace's first tab (its view made before the store's reply
    /// named it a new tab page): a chat that has no session yet becomes the
    /// page. A chat with a session keeps it.
    public func becomeNewTab(_ page: AgentPaneNewTab) {
        guard sessionId == nil else { return }
        newTab = page
    }

    /// The reply for one page request.
    public func respond(to request: AgentPaneRequest) async -> [String: Any] {
        switch request {
        // Boot traffic, and a request the host refused (it changed nothing), leave it untouched.
        case .ready, .reconnect, .framePacing, .renderRate, .checkpointAvailability, .painted, .unsupported,
             .transportOpen, .transportSend, .transportClose, .transportGesture, .transportGestureRelease: break
        default:
            if !userTouched { touchedBy = String(String(describing: request).prefix { $0 != "(" }) }
            userTouched = true
        }
        switch request {
        case .ready, .reconnect:
            setCheckpointAvailable(false)
            do {
                var handshake = request == .ready
                    ? try await host.handshake(sessionId: sessionId)
                    : try await host.reconnectHandshake(sessionId: sessionId)
                // Only a chat without a session yet starts from the seed.
                if sessionId == nil, let seed = await seed?.take() {
                    handshake.cwd = seed.cwd
                    handshake.draft = seed.draft
                    handshake.prompt = seed.prompt
                    handshake.harness = seed.harness
                    handshake.adopt = seed.adopt
                }
                // The surface holds after the chat has a session (a reload
                // of the quick panel stays compact).
                handshake.surface = seed?.surface
                // A new tab page is a new chat on every host, the mock included: the page
                // never falls back to the most recent session behind it. Its chat starts in
                // the page's folder unless a seed named one.
                if sessionId == nil, let newTab {
                    handshake.newTab = newTab
                    handshake.newSession = true
                    if handshake.cwd == nil { handshake.cwd = newTab.cwd }
                }
                handshake.linkScheme = linkScheme
                if sessionMustExist, sessionId != nil { handshake.sessionMustExist = true }
                handshake.revealTurn = pendingRevealTurn
                pendingRevealTurn = nil
                hasHandshake = true
                if let cwd = handshake.cwd { handshakeCwd = cwd }
                if let session = handshake.sessionId { transport.sessions.add(session) }
                // The connection stays here; the reply never encodes it.
                pendingConnection = handshake.connection
                handshake.connection = nil
                return AgentPaneReply.handshake(handshake)
            } catch {
                let message = AgentPaneHostError.userMessage(for: error)
                return AgentPaneReply.failure(code: "host_unavailable", message: message)
            }
        case .persistSession(let id):
            sessionMustExist = false
            if id != sessionId {
                sessionId = id
                newTab = nil
                onSessionChange?(id)
            }
            return AgentPaneReply.success()
        case .checkpointAvailability(let available):
            setCheckpointAvailable(available)
            return AgentPaneReply.success()
        case .framePacing(let intervals):
            return AgentPaneReply.success(onFramePacing?(intervals) ?? [:])
        case .renderRate(let full):
            onRenderRate?(full)
            return AgentPaneReply.success()
        case .painted:
            markPainted()
            return AgentPaneReply.success()
        case .openTab(let kind, let text, let cwd, let search, let run):
            guard newTab != nil || allowsTabConversion, let onOpenTab else { return Self.unsupported("tab.open") }
            onOpenTab(AgentPaneOpenTab(kind: kind, text: text, cwd: cwd, search: search, run: run))
            return AgentPaneReply.success()
        case .typeAhead(let text):
            guard newTab != nil || allowsTabConversion, let onTypeAhead else { return Self.unsupported("tab.typeAhead") }
            onTypeAhead(text)
            return AgentPaneReply.success()
        case .touched:
            return AgentPaneReply.success()
        case .shellRun, .shellRead, .shellStop: return await respondToShell(request)
        case .rememberNewTab(let agent):
            guard let onRememberNewTab else { return Self.unsupported("newTab.remember") }
            onRememberNewTab(agent)
            return AgentPaneReply.success()
        case .runAction(let id):
            // The page runs Import and Sync; any agent tab may open the New Tab page (a blank chat's New).
            guard id == "newTab.page" || (id == "palette.welcomeChecklist" && newTab != nil), let onRunAction else {
                return Self.unsupported("action.run")
            }
            onRunAction(id)
            return AgentPaneReply.success()
        case .jump(let target, let id):
            guard newTab != nil, let onJump else { return Self.unsupported("tab.jump") }
            onJump(target, id)
            return AgentPaneReply.success()
        case .setDefaultKind(let kind):
            guard newTab != nil, let onSetDefaultKind else { return Self.unsupported("tab.setDefaultKind") }
            onSetDefaultKind(kind)
            return AgentPaneReply.success()
        case .browseProject:
            guard let onBrowseProject else { return Self.unsupported("project.browse") }
            guard let cwd = await onBrowseProject() else { return AgentPaneReply.success() }
            return AgentPaneReply.success(["cwd": cwd])
        case .listProjects(let query):
            guard let onListProjects else { return Self.unsupported("project.list") }
            return AgentPaneReply.success(["projects": await onListProjects(query)])
        case .importAndSync:
            guard let onImportAndSync else { return Self.unsupported("onboarding.importAndSync") }
            onImportAndSync()
            return AgentPaneReply.success()
        case .paneAction, .tabState, .archive: return await respondToHeader(request)
        case .appAction(let id):
            guard newTab?.omnibar.actions.contains(where: { $0.id == id }) == true, let onAppAction else { return Self.unsupported("app.action") }
            onAppAction(id)
            return AgentPaneReply.success()
        case .editShortcut(let kind):
            guard let onEditShortcut else { return Self.unsupported("shortcut.edit") }
            onEditShortcut(kind)
            return AgentPaneReply.success()
        case .dictation(let command):
            guard let onDictation else { return AgentPaneReply.failure(code: "unsupported", message: "Dictation is unavailable") }
            onDictation(command)
            return AgentPaneReply.success()
        case .openFile(let path, let target):
            guard let onOpenFile else {
                return AgentPaneReply.failure(code: "open_failed", message: Self.openFileFailedMessage)
            }
            let url: URL
            switch checkedFileOpen(path, target: target) {
            case .success(let checked): url = checked
            case .failure(let refusal): return Self.transportFailure(refusal)
            }
            guard await onOpenFile(url, target) else {
                return AgentPaneReply.failure(code: "open_failed", message: Self.openFileFailedMessage)
            }
            return AgentPaneReply.success()
        case .quickDismiss:
            guard let onQuickDismiss else { return Self.unsupported("quick.dismiss") }
            onQuickDismiss()
            return AgentPaneReply.success()
        case .openPreview(let url):
            guard let onOpenPreview, onOpenPreview(url) else {
                return AgentPaneReply.failure(code: "open_failed", message: Self.openPreviewFailedMessage)
            }
            return AgentPaneReply.success()
        case .quickOpenInWindow(let session):
            guard let onQuickOpenInWindow else { return Self.unsupported("quick.openInWindow") }
            if let session, session != sessionId {
                sessionId = session
                newTab = nil
                onSessionChange?(session)
            }
            onQuickOpenInWindow(sessionId)
            return AgentPaneReply.success()
        case .git(let git):
            guard let onGit else { return Self.gitFailure(.notConnected) }
            do {
                let data = try await onGit(git)
                guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                    return Self.gitFailure(.failed)
                }
                return AgentPaneReply.success(value)
            } catch {
                return Self.gitFailure(error as? AgentPaneGitFailure ?? .failed)
            }
        case .invalidGit:
            return Self.gitFailure(.invalidRequest)
        case .transportOpen:
            guard let connection = pendingConnection else { return Self.transportFailure(.noConnection) }
            pendingConnection = nil
            do {
                return AgentPaneReply.success(["connection": try await transport.open(connection)])
            } catch {
                return Self.transportFailure(error)
            }
        case .transportSend(let connection, let frames):
            return Self.transportReply(await transport.send(connection: connection, frames: frames))
        case .transportGesture(let intent):
            guard let intent else { return Self.transportFailure(.intentInvalid) }
            guard let ticket = transport.reserveGesture(intent) else { return Self.transportFailure(.gestureRequired) }
            return AgentPaneReply.success(["ticket": ticket])
        case .transportGestureRelease:
            transport.gestures.clearTickets()
            return AgentPaneReply.success()
        case .transportClose(let connection):
            transport.close(connection: connection)
            return AgentPaneReply.success()
        case .unsupported(let method):
            return Self.unsupported(method)
        }
    }

    /// The page's reply to a `transport.send`.
    static func transportReply(_ error: AgentPaneTransportError?) -> [String: Any] {
        error.map(transportFailure) ?? AgentPaneReply.success()
    }

    private static func transportFailure(_ error: AgentPaneTransportError) -> [String: Any] {
        AgentPaneReply.failure(code: error.rawValue, message: transportFailedMessage, details: nil, retryable: nil, origin: "native")
    }

    private static func unsupported(_ method: String) -> [String: Any] {
        AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: \(method)")
    }

    private func setCheckpointAvailable(_ available: Bool) {
        guard checkpointAvailable != available else { return }
        checkpointAvailable = available
        onCheckpointAvailability?(available)
    }
}
