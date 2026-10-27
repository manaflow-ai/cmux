public import AppKit
public import CmuxNextActions
public import CmuxNextSettings
public import Foundation
public import Observation

/// One agent pane's host-side state: which acpmux session it shows. The
/// session, its transcript and every chat action live in acpmux and the
/// page; this only answers the page's host requests.
@Observable
public final class AgentPaneModel {
    /// The session the page last reported, nil for a new chat that has not sent its first prompt.
    public private(set) var sessionId: String?
    /// Page projection of its single session-host Git capability read, never an authorization grant.
    public private(set) var checkpointAvailable = false
    @ObservationIgnored public var onCheckpointAvailability: ((Bool) -> Void)?
    /// The page drew its first frame after the handshake (`pane.painted`), the
    /// first that shows what it is. Until then its pane keeps what it showed.
    public internal(set) var hasPainted = false
    /// That first frame drew a chat from a kept tail (`pane.painted`'s
    /// `drewKeptTail`, tailCache.ts): it is already on screen, so the pane's
    /// loading state shows the page in one frame instead of fading it in
    /// (``AgentPaneView/pageFades(hasNewTab:isVisible:fromKeptTail:)``). False
    /// for a chat read cold, for a page that says nothing, and for the host's
    /// own give-up path, each of which keeps the fade.
    public internal(set) var paintedFromKeptTail = false
    @ObservationIgnored var paintWaiters: [() -> Void] = []

    /// Called when the page switches to or creates a session, so the App can keep it with the tab.
    @ObservationIgnored public var onSessionChange: ((String) -> Void)?
    /// Called when acpmux reports the agent the pane's session runs (its `session/new` or
    /// `_acpmux/attach` reply; ``AcpmuxPaneSessions/harness(of:)``), so the App records the
    /// harness on the tab (cx-w4bbw). Only for the session the pane shows.
    @ObservationIgnored public var onSessionHarness: ((_ session: String) -> Void)?
    @ObservationIgnored public var onUnsentDraft: ((String) -> Void)? // a new chat's typed text, until it has a session
    /// Reports each settled scroll and returns the native display settings to the page.
    @ObservationIgnored public var onFramePacing: (([Double]) -> [String: Any])?
    /// Applies the page's adaptive rendering decision.
    @ObservationIgnored public var onRenderRate: ((Bool) -> Void)?
    /// The new tab page this pane shows until it has a session (cleared then), nil for a plain chat.
    public private(set) var newTab: AgentPaneNewTab? { didSet { if (oldValue == nil) != (newTab == nil) { onNewTabChange?() } } }
    @ObservationIgnored var onNewTabChange: (() -> Void)? // it became or left a New Tab page (the view's bar on top)
    /// Receives the current opening’s focused-field acknowledgement.
    @ObservationIgnored public var onNewTabInputReady: ((String) -> Void)?
    /// The new tab page chose a terminal or browser (`tab.open`).
    @ObservationIgnored public var onOpenTab: ((AgentPaneOpenTab) -> Void)?
    /// A redeemed Run attempt asks the App to open its enrolled worker's terminal (`run.attach`).
    @ObservationIgnored public var onRunAttach: (@MainActor (AgentPaneRunAttach) async throws -> Void)?
    /// What the user typed after `!` so far (`tab.typeAhead`).
    @ObservationIgnored public var onTypeAhead: ((String) -> Void)?
    /// The agent picked on the new tab screen, to remember (`newTab.remember`).
    @ObservationIgnored public var onRememberNewTab: ((AgentPaneRememberedPick) -> Void)?
    /// The new tab page's style switch picked a template, or its edit mode changed a widget.
    @ObservationIgnored public var onEditNewTab: ((AgentPaneNewTabEdit) -> Void)?
    /// The location bar picked an open tab or workspace (`tab.jump`).
    @ObservationIgnored public var onJump: ((AgentPaneJumpTarget, String) -> Void)?
    /// The new tab page asked to change a kind's shortcut.
    @ObservationIgnored public var onEditShortcut: ((AgentPaneTabKind) -> Void)?
    /// Runs an app action requested by an empty-state or new-tab control, with its string arguments.
    @ObservationIgnored public var onRunAction: ((String, [String: String]) -> Bool)?
    /// Resolves the explicit Browse… fallback in the project picker.
    @ObservationIgnored public var onBrowseProject: (() async -> String?)?
    /// A new chat's Sandboxed send (`sandbox.run`, hq#3367): the App runs one task on a throwaway
    /// Cloud VM behind Labs and answers the page's reply (the receipt, or a typed refusal). Nil: no
    /// sandboxes in this app.
    @ObservationIgnored public var onSandboxRun: (@MainActor (_ task: String, _ agent: String?, _ key: String) async -> [String: Any])?
    /// This pane's Sandboxed send, kept across a page reload (``AgentPaneSandboxRuns``).
    @ObservationIgnored public let sandboxRuns = AgentPaneSandboxRuns()
    /// Agent session avatars (the app's ``ChiefAvatarUploads``, keyed per session): the avatar as a
    /// small data URL, Set Avatar… (an open panel, then the upload; the new data URL, nil when
    /// cancelled or refused, which the app says itself) and Remove Avatar.
    /// A custom harness's SF Symbol icon for the page (`harness.symbol`); the app may share one
    /// cache between panes.
    @ObservationIgnored public var harnessSymbols = HarnessSymbolImages()
    @ObservationIgnored public var onAgentAvatar: ((String) async -> String?)?
    @ObservationIgnored public var onSetAgentAvatar: ((String) async -> String?)?
    @ObservationIgnored public var onRemoveAgentAvatar: ((String) -> Void)?
    /// Returns bounded project paths for the picker, optionally filtered by query.
    @ObservationIgnored public var onListProjects: ((String?) async -> [String])?
    /// The folders a chat on another machine can pick: that machine's (its workspace's folders
    /// there), never this Mac's (cx-k21v).
    @ObservationIgnored public var onListRemoteProjects: ((String?) async -> [String])?
    /// A chat on another machine (set by the host when it makes the page, and by a handshake that
    /// gives a remote connection; never cleared): the page's folder tools (project list, Browse,
    /// Choose Folder, Use Folder, the shell box) act there or are refused, never on this Mac (cx-k21v).
    @ObservationIgnored public var remoteChat = false
    /// Logs each missing-chat view the page reports (`chat.missing`).
    @ObservationIgnored let missingChatLog = AgentPaneMissingChatLog()
    @ObservationIgnored public var onOpenChat: ((String) -> Void)? // `chats.open`: the app's shared Open Chat path
    @ObservationIgnored public var onOpenChatInTerminal: ((String) -> Void)? // `chats.openInTerminal`: a row's right-click menu
    @ObservationIgnored public var onWatchChat: ((String) -> Void)? // `chats.watch`: View Only from a row's right-click menu
    @ObservationIgnored public var onChatsPage: ((AgentPaneChatsQuery) async -> AgentPaneChatsPage?)? // `chats.page` (cx-n0i9)
    /// The chat's own right-click menu on empty space: detached items the App renders from its placements.
    @ObservationIgnored public var chatMenuItems: (@MainActor () -> [NSMenuItem])?
    /// Search the Web on selected chat text: a browser tab with the omnibar's search engine.
    @ObservationIgnored public var onSearchWeb: (@MainActor (String) -> Void)?
    /// Runs an action advertised by the host's omnibar.
    @ObservationIgnored public var onAppAction: ((String) -> Void)?
    /// The chat header's tab actions and tab state (``AgentPaneHeaderHooks``).
    @ObservationIgnored public var header: AgentPaneHeaderHooks?
    /// The header's tools in the pane's tab row (``AgentPaneTabRow``, `ChromeTunables.tabRowTools`).
    @ObservationIgnored public let tabRow = AgentPaneTabRow()
    /// Gets the composer's dictation requests (the pane's mic).
    @ObservationIgnored public var onDictation: ((AgentPaneDictationCommand) -> Void)?
    /// Opens a changed file the page names; false when it could not.
    @ObservationIgnored public var onOpenFile: (@MainActor (URL, AgentPaneFileTarget, FileLineLocation?) async -> Bool)?
    /// Opens a turn's local web page in a browser tab beside the agent;
    /// false when it could not.
    @ObservationIgnored public var onOpenPreview: (@MainActor (URL) -> Bool)?
    /// Start Agent's panel (``AgentPaneQuickHooks``): its page's `quick.*` requests.
    @ObservationIgnored public var quick: AgentPaneQuickHooks?
    /// This build's URL scheme, handed to the page with every handshake so
    /// the links it copies open in this build; nil leaves it out.
    @ObservationIgnored public var linkScheme: String?
    /// A `#turn-<turnId>` link's turn the page has not been handed yet; the
    /// next handshake carries it (`revealTurn`) and clears it.
    @ObservationIgnored public var pendingRevealTurn: String?
    /// What this chat's last page held when it let go (hibernation); the next handshake
    /// carries it (`wake`) and clears it.
    @ObservationIgnored public var pendingWake: AgentPaneWakeState?
    /// The last quit's state of this chat while the launch still reads it (``AgentPaneRelaunchWake/hand(_:to:)``):
    /// the page's first `ready` awaits it into ``pendingWake``.
    @ObservationIgnored public var wakeSource: (@MainActor () async -> AgentPaneWakeState?)?
    /// The state the page's last `ready` took, kept for a quit the page does not answer in time.
    @ObservationIgnored public internal(set) var handedWake: AgentPaneWakeState?
    /// Whether the page has asked for a handshake, so its bridge is up and
    /// a turn can be revealed through it directly.
    @ObservationIgnored public internal(set) var hasHandshake = false
    /// The binary on the socket when the last handshake was refused with a daemon this app may
    /// replace: only then does `acpmux.restart` stop it, and only while that same binary holds
    /// the socket (``AgentPaneHandshakeReply/restartAcpmux(in:)``).
    @ObservationIgnored var acpmuxRestartOffered: AcpmuxSocketOwner?
    /// Runs a git read on the session host and returns its JSON result.
    /// Throws an ``AgentPaneGitFailure`` saying who failed; any other error
    /// reaches the page as `native.failed`.
    @ObservationIgnored public var onGit: (@MainActor (AgentPaneGitRequest) async throws -> Data)?
    /// Runs a commit or push on the session host in the given folder (the pane's session's,
    /// from the host) and returns its `MutationResult` as JSON; throws like ``onGit``.
    @ObservationIgnored public var onGitWrite: (@MainActor (AgentPaneGitWrite, String) async throws -> Data)?
    /// Whether the Changes view's git writes (cx-tcwj) may run here: only a chat on this Mac. Unset: never.
    @ObservationIgnored public var gitWritesHere: (@MainActor () -> Bool)?
    /// Moves a file the turn created to the Trash (`turn.undo`); tests replace it.
    @ObservationIgnored public var trashFile: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    /// Whether this pane's tab may turn into a terminal or browser tab (`tab.open`, `tab.typeAhead`): a local tab's, also one that adopted the spare (cx-ckt2z).
    @ObservationIgnored public package(set) var allowsTabConversion: Bool
    /// The host's acpmux socket for this pane (in the app the page never holds one).
    @ObservationIgnored public let transport: AgentPaneTransport
    @ObservationIgnored public let shell = AgentPaneShell() // shell mode: shell.run, shell.read, shell.stop
    /// The App's side of reply chips, images and the preview card's browsers.
    @ObservationIgnored public let replyLinks = AgentPaneReplyLinks()
    /// The last handshake's connection, until the page opens it: used once, so the LocalApp token is never kept beyond one handshake.
    @ObservationIgnored var pendingConnection: AcpmuxConnection?
    /// The folders of this pane's workspace the App knows (its local tabs' folders). With the
    /// handshake's cwd and the new tab page's folders they are the roots every `cwd` or `path`
    /// the page sends must be under (``AcpmuxPathPolicy``).
    @ObservationIgnored public var workspaceRoots: (@MainActor () -> [String])?
    /// The workspace's agent-home folder (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE): a root once it
    /// exists, and where a new chat starts when the workspace has no folder (no other root).
    @ObservationIgnored public var workspaceAgentHome: (@MainActor () -> AgentHomeFill?)?
    /// Where this pane's new chat starts: the store's answer and its rules (cx-9aps).
    @ObservationIgnored public let startFolders = AgentPaneStartFolders()
    /// Shows the native folder sheet for "Choose Folder…" and saves the pick as the workspace's
    /// agent folder; a refusal carries its localized text (an older background service, a save
    /// that failed).
    @ObservationIgnored public var onChooseFolder: (@MainActor () async -> AgentPaneFolderChoice)?
    /// Choose Folder… for a chat whose folder is missing: the native folder sheet on this pane,
    /// then acpmux's `chat_open` with the pick (cx-nn3e.1).
    @ObservationIgnored public var onChooseChatFolder: (@MainActor (_ chat: String) async -> AgentPaneChatFolderResult)?
    /// The folder this pane's user chose with "Choose Folder…": new chats start there until the
    /// workspace's own field (``workspaceRoots``) carries it.
    @ObservationIgnored public internal(set) var chosenFolder: String?
    @ObservationIgnored internal(set) var handshakeCwd: String?
    /// The project the person picked on the New Tab page (`workspace.useFolder`) before the first
    /// send: where a terminal from this pane starts until the chat's session names its own.
    @ObservationIgnored internal(set) var pickedFolder: String?
    /// Counts `workspace.useFolder` picks and folder choices, so a pick that finishes after a
    /// later one never replaces it (``notePicked(_:_:)``).
    @ObservationIgnored var pickSequence = 0

    /// Saves the inspector's exported log or a side panel document where the user picks; true
    /// when saved, false when the user cancelled. Nil leaves the page to copy the text instead.
    @ObservationIgnored public var onSaveFile: (@MainActor (AgentPaneSave) async throws -> Bool)?
    /// Add Files to Project's open panel: the files the user picked, none when they cancelled.
    @ObservationIgnored public var onChooseFiles: (@MainActor () async -> [URL])?
    /// Attach files or folders' open panel: what the user picked, none when they cancelled.
    @ObservationIgnored public var onChooseAttachments: (@MainActor () async -> [URL])?
    /// Whether this chat's folder is on this Mac and the chat was not moved to Cloud: files the
    /// person drops or pastes then go as their own paths (``AgentPaneDroppedPaths``). Nil: never.
    @ObservationIgnored public var onLocalPaths: (@MainActor () -> Bool)?
    /// The file URLs of the person's last native drop or paste on the page.
    @ObservationIgnored var droppedPaths = AgentPaneDroppedPaths()
    @ObservationIgnored public internal(set) var composer = AgentPaneComposerSetting.fallback
    /// The native Debug Settings baseline for the sidebar's latest-reply preview. A user's
    /// `layout.sidebarPreviewVariant` can temporarily override it in the page.
    @ObservationIgnored public internal(set) var sidebarPreviewVariant = AgentPaneSidebarPreviewVariant.card
    /// Diff Colors (`diff.colors`) as the page last got it: "theme", "muted" or "standard".
    @ObservationIgnored public internal(set) var diffColors = "theme"
    @ObservationIgnored public var onComposerSetting: (@MainActor ([String], Bool) async throws -> Void)?
    /// The chat's look as the page last got it, and where its popover writes (AgentPaneView+Display.swift).
    @ObservationIgnored public internal(set) var display = AgentPaneDisplaySetting.fallback
    @ObservationIgnored public var onDisplaySetting: (@MainActor ([String], JSONValue?) async throws -> Void)?
    /// The chat's tool cards (``AgentPaneToolCard``), and the App's answer to a click on one: the card's id, the button's
    /// and what the person typed in the card's field, if the button sends it.
    @ObservationIgnored public internal(set) var toolCards: [AgentPaneToolCard] = []
    @ObservationIgnored public var onToolCard: (@MainActor (_ card: String, _ action: String, _ value: AgentPaneToolCard.Entered?) -> Void)?
    /// The App's upload for this chat (a chat moved to a Cloud machine), nil when it takes none (``AgentPaneUpload``).
    @ObservationIgnored public var onUpload: (@MainActor () -> AgentPaneUploader?)?
    @ObservationIgnored public var onUploadStage: (@MainActor () -> AgentPaneUploadStager?)?
    /// App-owned, explicitly confirmed provider credential setup for this pane's Cloud chat.
    @ObservationIgnored public var onCloudCredentialTransfer: (@MainActor (AgentPaneCloudCredentialTransferRequest) async -> Bool)?

    @ObservationIgnored let host: any AgentPaneHostProviding
    /// The page's host is another machine's (cx-k21v): it never becomes this Mac's prewarmed spare.
    @ObservationIgnored public var neverPooled = false
    /// What a new chat inherits from the tab it was opened from.
    @ObservationIgnored let seed: AgentPaneSeedSource?

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
        transport.agentHome = { [weak self] in self?.startFolders.answer?.agentHomeFill ?? self?.workspaceAgentHome?() }
        if let sessionId { transport.sessions.add(sessionId) }
        transport.requestModeConfirmation = { [weak self] asked, answer in
            guard let onConfirmMode = self?.onConfirmMode else { return answer(false) }
            onConfirmMode(asked, answer)
        }
        transport.requestHarnessEnable = { [weak self] prompt, answer in
            guard let onConfirmHarness = self?.onConfirmHarness else { return answer(false) }
            onConfirmHarness(prompt, answer)
        }
        transport.sessions.onHarness { [weak self] session, _ in
            // task-owner: one hop to the main actor per reply that names a session's harness
            Task { @MainActor in
                guard let self, session == self.sessionId else { return }
                self.onSessionHarness?(session)
            }
        }
    }

    /// Asks the user to confirm a config option that is not free (the view's native sheet).
    @ObservationIgnored public var onConfirmMode: (@MainActor (_ asked: AgentPaneModeConfirmation, _ answer: @escaping @MainActor (Bool) -> Void) -> Void)?

    /// Asks the user to enable a folder harness profile (the view's native Enable harness sheet).
    @ObservationIgnored public var onConfirmHarness: (@MainActor (_ prompt: AgentPaneHarnessEnablePrompt, _ answer: @escaping @MainActor (Bool) -> Void) -> Void)?

    /// Cmd-T adopted this prewarmed new tab page: `page` is the context of the tab it became
    /// (plans/cmux-next/new-tab.md section 2.2). A page that already became a chat keeps its chat.
    /// User input reached the page, or it ran any op beyond boot (the handshake, frame pacing, render
    /// rate, capabilities). A touched page is never recycled into the prewarm pool (coordinator: strictly untouched).
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
    public func respond(to request: AgentPaneRequest, userGesture: Bool = false) async -> [String: Any] {
        switch request {
        // Boot traffic, and a request the host refused (it changed nothing), leave it untouched.
        case .ready, .reconnect, .uiPointerReport, .framePacing, .renderRate, .checkpointAvailability, .painted, .newTabInputReady, .newTabContext, .newTabWarm, .unsupported,
             .transportOpen, .transportSend, .transportClose, .transportGesture, .transportGestureRelease, .chatsPage, .quickFloatingState, .quickContext,
             .tabRowTools, .projectIcon, .agentAvatar, .harnessSymbol, .environment(.list), .cloudMachine(.list), .sandboxState: break
        case .reply(let reply) where reply.isPassive: break
        default:
            if !userTouched { touchedBy = String(String(describing: request).prefix { $0 != "(" }) }
            userTouched = true
        }
        switch request {
        case .uiPointerReport: return AgentPaneReply.success()
        case .ready, .reconnect:
            return await AgentPaneHandshakeReply.reply(to: request, in: self)
        case .restartAcpmux: return await AgentPaneHandshakeReply.restartAcpmux(in: self)
        case .persistSession(let id): adoptSession(id); return AgentPaneReply.success()
        case .missingChat(let session, let reason):
            missingChatLog.record(session: session, reason: reason, tabSession: sessionId, remote: remoteChat)
            return AgentPaneReply.success()
        case .unsentDraft(let text): if sessionId == nil { onUnsentDraft?(text) }; return AgentPaneReply.success()
        case .checkpointAvailability(let available):
            setCheckpointAvailable(available)
            return AgentPaneReply.success()
        case .framePacing(let intervals):
            return AgentPaneReply.success(onFramePacing?(intervals) ?? [:])
        case .renderRate(let full):
            onRenderRate?(full)
            return AgentPaneReply.success()
        case .painted(let fromKeptTail):
            AgentPaneLaunchTimings.shared.mark(newTab != nil ? "agent_pane.newtab_painted" : "agent_pane.painted")
            // The first report only, and before `markPainted`: the pane's loading state leaves on
            // that call, and what that frame drew is what decides whether the page fades in
            // (``AgentPaneView/pageFades``). A later report describes a frame nothing is waiting on.
            if !hasPainted { paintedFromKeptTail = fromKeptTail }
            markPainted()
            return AgentPaneReply.success()
        case .openTab(let request): return request.open(in: self)
        case .runAttach(let request): return await request.attach(in: self)
        case .invalidRunAttach: return AgentPaneRunAttach.invalidReply
        case .typeAhead(let text): return AgentPaneOpenTab.typeAhead(text, in: self)
        case .touched: return AgentPaneReply.success()
        // The shell box runs on this Mac: never for a chat on another machine (cx-k21v).
        case .shellRun, .shellRead, .shellStop:
            if remoteChat { return Self.unsupported("shell") }
            return await respondToShell(request)
        case .shellComplete(let line, let cwd):
            if remoteChat { return Self.unsupported("shell") }
            return await respondToShellComplete(line: line, cwd: cwd)
        case .newTabContext:
            AgentPaneLaunchTimings.shared.mark("agent_pane.newtab_context")
            // Only a page with no chat yet is a New Tab page; the handshake still sends the same context.
            guard sessionId == nil, let newTab, let data = try? JSONEncoder().encode(newTab),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return AgentPaneReply.success() }
            return AgentPaneReply.success(["newTab": object])
        // Another machine's chats are not this Mac's: only a local page's list warms the next page.
        case .newTabWarm(let warm): if !remoteChat { AgentPaneNewTab.warmed = warm }; return AgentPaneReply.success()
        case .newTabInputReady(let token): guard newTab?.inputToken == token else { return Self.unsupported("newTab.inputReady") }; onNewTabInputReady?(token); return AgentPaneReply.success()
        case .rememberNewTab(let pick): guard let onRememberNewTab else { return Self.unsupported("newTab.remember") }; onRememberNewTab(pick); return AgentPaneReply.success()
        case .editNewTab(let edit): guard let onEditNewTab else { return Self.unsupported(edit.method) }; onEditNewTab(edit); return AgentPaneReply.success()
        case .nowPlaying(let command): return AgentPaneNowPlaying.shared.perform(command) ? AgentPaneReply.success() : Self.unsupported("nowPlaying.command")
        case .runAction(let id): return runAction(id)
        case .jump(let target, let id): guard newTab != nil, let onJump else { return Self.unsupported("tab.jump") }; onJump(target, id); return AgentPaneReply.success()
        case .chooseFolder where remoteChat: return Self.unsupported("workspace.chooseFolder")
        case .chooseFolder: return await chooseFolder()
        case .chooseChatFolder: return await chooseChatFolder()
        // The panel picks this Mac's files: never for a chat on another machine (cx-k21v).
        case .chooseAttachments where remoteChat: return Self.unsupported("chat.attach.choose")
        case .chooseAttachments: return await chooseAttachments()
        // Nor the paths of files dropped or pasted from this Mac.
        case .attachDropped where remoteChat: return Self.unsupported("chat.attach.dropped")
        case .attachDropped(let kind, let names): return await attachDropped(kind, names: names)
        case .useFolder(let cwd, let confirm) where remoteChat:
            // A folder of that machine: its store answers as this Mac's does (cx-1bhjj), its acpmux
            // checks the folder and its trust at the start; this Mac's disk is never read (cx-k21v).
            guard cwd.hasPrefix("/") else { return Self.transportFailure(.pathInvalid) }
            return await startFolders.useRemote(cwd, confirm: confirm, transport: transport)
        case .useFolder(let cwd, let confirm):
            let pick = beginPick()
            return await notePicked(pick, startFolders.use(cwd, confirm: confirm, transport: transport))
        case .browseProject where remoteChat: return Self.unsupported("project.browse")
        case .listProjects(let query) where remoteChat:
            return AgentPaneReply.success(["projects": await onListRemoteProjects?(query) ?? []])
        case .browseProject:
            guard let onBrowseProject else { return Self.unsupported("project.browse") }
            guard let cwd = await onBrowseProject() else { return AgentPaneReply.success() }
            return AgentPaneReply.success(["cwd": await transport.pick(cwd)])
        case .agentAvatar(let session):
            guard let src = await onAgentAvatar?(session) else { return AgentPaneReply.success() }
            return AgentPaneReply.success(["src": src])
        case .setAgentAvatar(let session):
            guard let onSetAgentAvatar else { return Self.unsupported("agent.avatar.set") }
            let src = await onSetAgentAvatar(session)
            return AgentPaneReply.success(src.map { ["src": $0] } ?? [:])
        case .harnessSymbol(let name):
            return AgentPaneReply.success(harnessSymbols.dataURL(name).map { ["src": $0] } ?? [:])
        case .removeAgentAvatar(let session):
            onRemoveAgentAvatar?(session)
            return AgentPaneReply.success()
        case .projectIcon where remoteChat:
            // A chat on another machine: its folders are there, and this Mac's disk is never read (cx-k21v).
            return AgentPaneReply.success()
        case .projectIcon(let cwd):
            // Off the main actor, cached by file and modification date; neither keeps the page's letters.
            let answer = await AgentPaneProjectIcons.shared.answer(for: cwd)
            var value: [String: Any] = [:]
            if let src = answer.src { value["src"] = src }
            if let glyph = answer.glyph { value["glyph"] = glyph }
            return AgentPaneReply.success(value)
        case .listProjects(let query):
            guard let onListProjects else { return Self.unsupported("project.list") }
            // Each folder's repository, so the pickers fold worktrees under their repository.
            let projects = await onListProjects(query)
            return AgentPaneReply.success(["projects": projects, "repos": await AgentPaneProjectRepoReader.replies(for: projects)])
        case .openChat(let key): if let onOpenChat { onOpenChat(key); return AgentPaneReply.success() } else { return Self.unsupported("chats.open") }
        case .openChatInTerminal(let key): if let onOpenChatInTerminal { onOpenChatInTerminal(key); return AgentPaneReply.success() } else { return Self.unsupported("chats.openInTerminal") }
        case .watchChat(let key): if let onWatchChat { onWatchChat(key); return AgentPaneReply.success() } else { return Self.unsupported("chats.watch") }
        case .chatsPage(let query): return await respondToChatsPage(query)
        case .environment(let request): return await request.reply(store: startFolders.environments, newTabPage: newTab != nil && sessionId == nil)
        case .sandboxRun(let task, let agent, let key):
            // A new chat only, and it spends Cloud time: the Send's own gesture, as a git write.
            // Not once a chat starts or opens here (it would replace the run's result), and one at a time;
            // while it runs no chat starts or opens here. The send line drains first, so a start or
            // open the page handed over before this is counted.
            guard sessionId == nil, let onSandboxRun else { return Self.unsupported("sandbox.run") }
            let notNow = AgentPaneReply.failure(code: "unavailable_now", message: "unavailable_now")
            guard await transport.lineDrained(within: .seconds(5)) else { return notNow }
            if let refusal = sandboxRuns.refusal { return AgentPaneReply.failure(code: refusal, message: refusal) }
            let replacements = transport.replacements
            guard replacements.beginSandbox() else { return notNow }
            guard transport.gestures.consume() else {
                replacements.endSandbox()
                return Self.transportFailure(.gestureRequired)
            }
            return await sandboxRuns.run(task: task, key: key) {
                defer { replacements.endSandbox() }
                return await onSandboxRun(task, agent, key)
            }
        case .sandboxState(let wait):
            return await sandboxRuns.state(wait: wait)
        case .cloudMachine(let request): return await request.reply(.shared, gestures: transport.gestures)
        case .cloudCredentialTransfer(let request):
            guard remoteChat, newTab == nil, sessionId == request.sessionID else {
                return AgentPaneReply.failure(code: "unavailable", message: "Credential setup is unavailable for this chat.")
            }
            guard let onCloudCredentialTransfer else { return Self.unsupported(AgentPaneCloudCredentialTransferRequest.method) }
            guard let connection = transport.connection,
                  let intent = AgentPaneGestureIntent(gestureParams: ["intent": ["method": "session/prompt", "params": [
                    "promptId": request.retryPromptID, "sessionId": request.sessionID,
                  ]]]), let ticket = transport.reserveGesture(intent) else { return Self.transportFailure(.gestureRequired) }
            var released = false
            defer { if !released { _ = transport.gestures.redeem(ticket, connection: connection, pick: nil) } }
            guard await onCloudCredentialTransfer(request), !Task.isCancelled,
                  transport.connection == connection, sessionId == request.sessionID else {
                return AgentPaneReply.success(["transferred": false])
            }
            // Preserve the original click's one-use, session/prompt-scoped grant and expiry.
            released = true
            return AgentPaneReply.success(["transferred": true, "promptId": request.retryPromptID, "ticket": ticket])
        case .paneAction, .diffTurn, .preview, .setQuickActions, .tabState, .tabRowTools, .sideChat, .subagentPane, .processTerminal, .chatTab, .offerOpen, .asksOpen, .asksAnswer, .newChatHere: return await respondToHeader(request)
        case .appAction(let id):
            guard newTab?.omnibar.actions.contains(where: { $0.id == id }) == true, let onAppAction else { return Self.unsupported("app.action") }
            onAppAction(id)
            return AgentPaneReply.success()
        case .editShortcut(let kind): guard let onEditShortcut else { return Self.unsupported("shortcut.edit") }; onEditShortcut(kind); return AgentPaneReply.success()
        case .dictation(let command):
            guard let onDictation else { return AgentPaneReply.failure(code: "unsupported", message: "Dictation is unavailable") }
            onDictation(command)
            return AgentPaneReply.success()
        case .openFile(let path, let target): return await openFile(path, target: target)
        case .quickDismiss, .quickSetOnTop, .quickSetCollapsed, .quickFloatingState, .quickContext, .quickOpenInWindow, .quickStartInBackground:
            return await quick?.respond(to: request, in: self) ?? Self.unsupported(String(describing: request))
        case .openPreview(let url):
            guard let onOpenPreview, onOpenPreview(url) else {
                return AgentPaneReply.failure(code: "open_failed", message: Self.openPreviewFailedMessage)
            }
            return AgentPaneReply.success()
        case .gitWrite(let write): return await AgentPaneGitWriteReply.reply(to: write, in: self)
        case .git, .invalidGit, .githubRepository, .gitStage, .gitPullRequest, .transportOpen, .transportSend, .transportGesture, .transportGestureRelease, .transportClose, .harnessUpdate, .harnessRestart:
            return await AgentPaneTransportReply.reply(to: request, in: self)
        case .turnUndo(let undo): return await AgentPaneTurnUndo.reply(to: undo, in: self)
        case .invalidTurnUndo: return await AgentPaneTurnUndo.reply(to: nil, in: self)
        case .projectInstructions, .projectAddFiles, .composerCapture: return await AgentPaneProjectFiles.respond(to: request, in: self)
        case .reply(let reply):
            replyLinks.remoteImageLoader = transport.remoteImageLoader
            return await respond(to: reply)
        case .saveFile(let save): return await saveFile(save)
        case .composerSetting(let path, let show): return await setComposer(path, show, userGesture: userGesture)
        case .displaySetting(let path, let value): return await setDisplay(path, value)
        case .toolCard(let card, let action, let value): return AgentPaneToolCard.respond(card: card, action: action, value: value, in: self)
        case .upload(let files): return await AgentPaneUpload.respond(files, in: self)
        case .uploadStage(let stage):
            guard let stager = onUploadStage?(), let sessionId else { return Self.unsupported("chat.upload.stage") }
            if case .begin(_, _, let batchToken, _) = stage, batchToken == nil, !transport.gestures.consume() { return Self.transportFailure(.gestureRequired) }
            return await stager(stage, sessionId)
        case .unsupported(let method): return Self.unsupported(method)
        }
    }

    /// The page's chat became session `id` (it started, or the quick panel moved it); no longer a new tab page.
    func adoptSession(_ id: String) {
        guard id != sessionId else { return }
        sessionId = id
        newTab = nil
        onSessionChange?(id)
    }

    func setCheckpointAvailable(_ available: Bool) {
        guard checkpointAvailable != available else { return }
        checkpointAvailable = available
        onCheckpointAvailability?(available)
    }
}
