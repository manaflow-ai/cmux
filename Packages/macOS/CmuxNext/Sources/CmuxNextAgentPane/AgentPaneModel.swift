public import AppKit
public import CmuxNextDesign
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
    /// The page commands the native palette may run in this chat now (`pane.commandAvailability`).
    public internal(set) var pageCommands: Set<String> = []
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
    /// The page's acpmux client is connected and its page actions answer (`pane.clientReady`); false
    /// while it connects or after it lost its connection. A prewarmed New Tab page serves a tab
    /// opening an existing chat only while this holds (`NewTabSparePool.takeConnectedSpare`).
    @ObservationIgnored public internal(set) var clientReady = false

    /// Called when the page switches to or creates a session, so the App can keep it with the tab.
    @ObservationIgnored public var onSessionChange: ((String) -> Void)?
    @ObservationIgnored var onQuestionKeySessionChange: (() -> Void)?
    /// Called when acpmux reports the agent the pane's session runs (its `session/new` or
    /// `_acpmux/attach` reply; ``AcpmuxPaneSessions/harness(of:)``), so the App records the
    /// harness on the tab (cx-w4bbw). Only for the session the pane shows.
    @ObservationIgnored public var onSessionHarness: ((_ session: String) -> Void)?
    @ObservationIgnored public var onUnsentDraft: ((String) -> Void)? // a new chat's typed text, until it has a session
    @ObservationIgnored public var machineLink: AgentPaneMachineLink? // the chat's machine dot (``AgentPanePageHost/currentEvents(_:)``)
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
    /// sandboxes in this app. `incognito` is ``sendIsIncognito``'s answer as the send was issued.
    @ObservationIgnored public var onSandboxRun: (@MainActor (_ task: String, _ agent: String?, _ key: String, _ incognito: Bool) async -> [String: Any])?
    /// Whether this pane's tab is in an incognito window now, as the App knows it. Read when a
    /// Sandboxed send is issued, before its send line drains: the tab may close during that wait
    /// (#31109). Nil: taken as incognito.
    @ObservationIgnored public var sendIsIncognito: (@MainActor () -> Bool)?
    /// A Cloud chat's hand-off turn (`cloud.handoffTurn`, ``AgentPaneHandoffPrompt``): the App opens
    /// it and answers `{turn}` or a refusal. Nil: no hand-offs in this app.
    /// Another machine picked for this pane's Cloud chat whose first send has not run
    /// (``AgentPaneCloudRepick``): the App moves the chat there and sends its first prompt again.
    @ObservationIgnored public var onCloudRepickChat: (@MainActor (AgentPaneCloudRepick) async -> [String: Any])?
    @ObservationIgnored public var onCloudHandoffTurn: (@MainActor (_ sessionId: String) async -> [String: Any])?
    /// The session a pane with no chat yet asked hand-off turns for (`cloud.handoffTurn`).
    @ObservationIgnored private var handoffSession: String?
    /// A new chat's first send with Cloud picked (``AgentPaneCloudStart``); nil: no Cloud chats here.
    @ObservationIgnored public var onCloudStartChat: (@MainActor (AgentPaneCloudStart) async -> [String: Any])?
    /// Reads this Mac's local repository catalog through its cmux daemon frame connection.
    @ObservationIgnored public var onCloudRepositoryLocal: (@MainActor () async throws -> Data)?
    /// For a Cloud chat, forwards machine actions through its tab host even while the page's
    /// ACP transport is a local connection.
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
    /// `chief.face`: Chief `chief`'s name and avatar as the sidebar shows them (`name`, `src` or `text`).
    @ObservationIgnored public var onChiefFace: ((String) async -> [String: String])?
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
    /// Declarative native controls published by the page for the shared tab row.
    public private(set) var tabRowTools: [PaneTabRowTool] = []
    @ObservationIgnored public var onTabRowToolInvoked: ((String, String?) -> Void)?
    /// Gets the composer's dictation requests (the pane's mic).
    @ObservationIgnored public var onDictation: ((AgentPaneDictationCommand) -> Void)?
    /// Takes back a long recording the pane's dictation gave the page, for chat `session`
    /// (``AgentPaneDictation/takeRecording(_:session:)``); nil for any other path.
    @ObservationIgnored var onDictationRecording: ((_ path: String, _ session: String) -> AgentPaneIssuedRecording?)?
    /// Gives back a long recording of chat `session` whose upload failed, so the page may try again
    /// (``AgentPaneDictation/giveBackRecording(_:session:)``).
    @ObservationIgnored var onDictationRecordingUnsent: ((_ recording: AgentPaneIssuedRecording, _ session: String) -> Void)?
    /// The long recordings uploading now, and the ones whose chip's × stopped them.
    @ObservationIgnored var dictationUploads = AgentPaneDictationUploads()
    /// Opens a changed file the page names; false when it could not.
    @ObservationIgnored public var onOpenFile: (@MainActor (URL, AgentPaneFileTarget) async -> Bool)?
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
    /// Share with Me: grants the signed-in person chats on this remote chat's Cloud machine.
    @ObservationIgnored public var onShareMachineWithMe: (@MainActor () async -> AgentPaneMachineShare)?
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
    /// Where a dropped screenshot or recording preview is kept (``retainedDropURLs``); tests point it elsewhere.
    @ObservationIgnored var chatUploadFolders = ChatUploadFolders.standard
    /// The icons of the apps this pane said attachments came from (`attachment.sourceIcon`).
    @ObservationIgnored let sourceIcons = AttachmentSourceIcons()
    @ObservationIgnored public internal(set) var composer = AgentPaneComposerSetting.fallback
    /// The native Debug Settings baseline for the sidebar's latest-reply preview. A user's
    /// `layout.sidebarPreviewVariant` can temporarily override it in the page.
    @ObservationIgnored public internal(set) var sidebarPreviewVariant = AgentPaneSidebarPreviewVariant.card
    /// Diff Colors (`diff.colors`) as the page last got it: "theme", "muted" or "standard".
    @ObservationIgnored public internal(set) var diffColors = "theme"
    @ObservationIgnored public var onComposerSetting: (@MainActor ([String], Bool) async throws -> Void)?
    /// The chat's look as the page last got it, and where its popover writes (AgentPaneView+Display.swift).
    @ObservationIgnored public internal(set) var display = AgentPaneDisplaySetting.fallback
    /// The app's feature tip records (`tips.state`); a test gives its own defaults.
    @ObservationIgnored public var featureTipRecords = AgentPaneFeatureTipRecords()
    @ObservationIgnored public var onDisplaySetting: (@MainActor ([String], JSONValue?) async throws -> Void)?
    /// The chat's tool cards (``AgentPaneToolCard``), and the App's answer to a click on one: the card's id, the button's
    /// and what the person typed in the card's field, if the button sends it.
    @ObservationIgnored public internal(set) var toolCards: [AgentPaneToolCard] = []
    @ObservationIgnored public var onToolCard: (@MainActor (_ card: String, _ action: String, _ value: AgentPaneToolCard.Entered?) -> Void)?
    /// The chat's live preview card (``AgentPaneComputerUsePreview``), and the App's answer to a click on it (its session).
    @ObservationIgnored public internal(set) var computerUsePreview: AgentPaneComputerUsePreview?
    @ObservationIgnored public var onComputerUsePreview: (@MainActor (_ session: String, _ action: AgentPaneComputerUsePreview.Action) -> Void)?
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
        (self.sessionId, self.seed) = (sessionId, seed)
        self.newTab = sessionId == nil ? newTab : nil
        sandboxRuns.restore(seed?.sandboxResult)
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

    /// The app's one Read aloud voice (``AgentPaneReadAloud``); nil refuses the page's speaker.
    @ObservationIgnored public var readAloud: AgentPaneReadAloud?
    /// Session Info's Remote Control switch (``AgentPaneRemoteControl``, the iPhone host's); nil: no row.
    @ObservationIgnored public var remoteControl: AgentPaneRemoteControl?
    /// The app's Cloud machines for `cloudMachine.*` (``AgentPaneCloudMachines``); nil refuses every method.
    @ObservationIgnored public var cloudMachines: AgentPaneCloudMachines?
    @ObservationIgnored public var onCloudEnvironment: (@MainActor (AgentPaneCloudEnvironmentRequest) async -> [String: Any])?
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

    /// A tab bound to session `session` (an existing chat it opens) adopted this prewarmed, connected
    /// New Tab page: the model is that tab's from here, as if its handshake had named the session
    /// (``AgentPaneView/adoptSession(_:revealTurn:)``). Its first paint is ahead again: the pane
    /// keeps its cover until the page draws the chat. False, changing nothing, for a page that is
    /// not an untouched, connected New Tab page.
    @discardableResult
    public func adoptSpareSession(_ session: String) -> Bool {
        guard sessionId == nil, newTab != nil, hasHandshake, !userTouched, !remoteChat, !neverPooled else { return false }
        sessionId = session
        transport.sessions.add(session)
        newTab = nil
        // The spare's start folder was no tab's; the chat's folder comes with its session.
        handshakeCwd = nil
        (hasPainted, paintedFromKeptTail) = (false, false)
        return true
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
        case .ready, .reconnect, .uiPointerReport, .framePacing, .renderRate, .checkpointAvailability, .commandAvailability, .painted, .clientReady, .newTabInputReady, .newTabContext, .newTabWarm, .unsupported,
             .transportOpen, .transportSend, .transportClose, .transportGesture, .transportGestureRelease, .chatsPage, .quickFloatingState, .quickContext,
             .tabRowTools, .tabRowToolsSet, .projectIcon, .agentAvatar, .chiefFace, .harnessSymbol, .attachmentSourceIcon, .environment(.list), .cloudMachine(.list), .cloudMachine(.recoveryList),
             .sandboxState, .subagentShown: break
        // The composer reports whether its harness takes audio on every mount (dictation.ts), and the
        // header, project notice and New Tab project list read their state on mount: boot traffic too (HQ#5914).
        case .dictation(.recordAudio), .tabState, .projectInstructions, .listProjects: break
        case .reply(let reply) where reply.isPassive: break
        case .cloudEnvironment(let request) where request.action != "update": break
        default:
            let name = String(String(describing: request).prefix { $0 != "(" })
            if touchedBy?.split(separator: ",").contains(Substring(name)) != true, (touchedBy?.count ?? 0) < 200 {
                touchedBy = touchedBy.map { $0 + "," + name } ?? name
            }
            userTouched = true
        }
        switch request {
        case .uiPointerReport: return AgentPaneReply.success()
        case .ready, .reconnect:
            return await AgentPaneHandshakeReply.reply(to: request, in: self)
        case .restartAcpmux: return await AgentPaneHandshakeReply.restartAcpmux(in: self)
        case .restartStuckAcpmux: return await AgentPaneHandshakeReply.restartStuckAcpmux(in: self)
        case .persistSession(let id): adoptSession(id); return AgentPaneReply.success()
        case .missingChat(let session, let reason):
            missingChatLog.record(session: session, reason: reason, tabSession: sessionId, remote: remoteChat)
            return AgentPaneReply.success()
        case .unsentDraft(let text): if sessionId == nil { onUnsentDraft?(text) }; return AgentPaneReply.success()
        case .checkpointAvailability(let available):
            setCheckpointAvailable(available)
            return AgentPaneReply.success()
        case .commandAvailability(let commands):
            pageCommands = Set(commands)
            return AgentPaneReply.success()
        case .clientReady(let ready):
            clientReady = ready
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
        case .readAloud(let command):
            guard let readAloud else { return Self.unsupported("readAloud") }
            if case .speak(let id, let text, let language) = command { readAloud.speak(text, id: id, language: language, owner: self) } else { readAloud.stop() }
            return AgentPaneReply.success()
        case .runAction(let id, let session): return runAction(id, session: session)
        case .jump(let target, let id): guard newTab != nil, let onJump else { return Self.unsupported("tab.jump") }; onJump(target, id); return AgentPaneReply.success()
        case .chooseFolder where remoteChat: return Self.unsupported("workspace.chooseFolder")
        case .chooseFolder: return await chooseFolder()
        case .chooseChatFolder: return await chooseChatFolder()
        case .shareMachineWithMe: return await shareMachineWithMe(userGesture: userGesture)
        // The panel picks this Mac's files: never for a chat on another machine (cx-k21v).
        case .chooseAttachments where remoteChat: return Self.unsupported("chat.attach.choose")
        case .chooseAttachments: return await chooseAttachments()
        // Nor the paths of files dropped or pasted from this Mac.
        case .attachDropped where remoteChat: return Self.unsupported("chat.attach.dropped")
        case .attachDropped(let kind, let names): return await attachDropped(kind, names: names)
        // A chat on another machine gets the gesture's source only (`attachSource`).
        case .attachSource(let kind, let names, let gestureAt): return await attachSource(kind, names: names, gestureAt: gestureAt)
        case .attachmentSourceIcon(let bundleId):
            return AgentPaneReply.success(sourceIcons.dataURL(bundleId).map { ["src": $0] } ?? [:])
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
            // `machine`: the folders are the chat's machine's, so its folder menu lists them and a
            // pick there goes through `workspace.useFolder` (cmux#29213).
            return AgentPaneReply.success(["projects": await onListRemoteProjects?(query) ?? [], "machine": true])
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
        case .chiefFace(let chief):
            return AgentPaneReply.success(await onChiefFace?(chief) ?? [:])
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
        // A new chat's send elsewhere spends Cloud time: the Send's own gesture (``AgentPaneHandOff``).
        case .sandboxRun(let task, let agent, let key): return await AgentPaneHandOff(model: self).sandbox(task: task, agent: agent, key: key)
        case .cloudStartChat(let start): return await AgentPaneHandOff(model: self).cloud(start)
        // Only a chat on another machine, on the person's own pick (one gesture).
        case .cloudRepickChat(let repick):
            guard let onCloudRepickChat, remoteChat, newTab == nil else { return Self.unsupported("cloud.repickChat") }
            guard transport.gestures.consume() else { return Self.transportFailure(.gestureRequired) }
            return await onCloudRepickChat(repick)
        case .sandboxState(let wait):
            return await sandboxRuns.state(wait: wait)
        case .cloudHandoffTurn(let session):
            // Only this pane's own chat on another machine: its chat, or the one it is starting now
            // (a remote chat's session is made by its first send, just before this ask). A pane
            // with no chat yet is held to the first session it asks for.
            let own = sessionId ?? handoffSession ?? session
            guard let onCloudHandoffTurn, remoteChat, own == session else {
                return Self.unsupported("cloud.handoffTurn")
            }
            if sessionId == nil { handoffSession = session }
            return await onCloudHandoffTurn(session)
        case .cloudMachine(let request): return await request.reply(cloudMachines, gestures: transport.gestures)
        case .cloudRepository(let request):
            return await request.reply(remoteChat: remoteChat, sessionID: sessionId,
                                       request: transport.cloudRepository ?? { [host] method, params, timeout in
                                           try await host.cloudRepository(method: method, params: params, timeout: timeout)
                                       },
                                       localRequest: onCloudRepositoryLocal)
        case .cloudEnvironment(let request):
            guard let onCloudEnvironment else { return Self.unsupported("cloud.environment.\(request.action)") }
            if request.action == "update", !transport.gestures.consume() {
                return Self.transportFailure(.gestureRequired)
            }
            return await onCloudEnvironment(request)
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
        case .btwInline(let question, let sessionId):
            // Handshake-attached panes keep the daemon path in `acpmuxSocket`; direct
            // transport tests and pre-handshake calls retain the connection path.
            guard !remoteChat, self.sessionId == sessionId,
                  let socketPath = transport.acpmuxSocket ?? transport.socketPath else {
                return Self.unsupported("chat.btw.inline")
            }
            guard transport.gestures.consume() else { return Self.transportFailure(.gestureRequired) }
            do {
                let result = try await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/btw",
                    params: ["sessionId": sessionId, "question": question, "inline": true, "_meta": ["acpmux": ["via": "app"]]], deadline: .seconds(120), detailed: true)
                guard let text = result["text"] as? String, !text.isEmpty else {
                    return AgentPaneReply.failure(code: "btw_failed", message: "Inline side question failed")
                }
                return AgentPaneReply.success(["text": text])
            } catch let refusal as AcpmuxRPCError where refusal.name == "trust.pending" || refusal.name == "trust.untrusted" {
                let reason = refusal.name ?? "trust.pending"
                var details: [String: Any] = ["reason": reason]
                if let cwd = refusal.cwd { details["cwd"] = cwd }
                return AgentPaneReply.failure(code: reason, message: refusal.message, details: details, retryable: true, origin: "session_host")
            } catch {
                return AgentPaneReply.failure(code: "btw_failed", message: "Inline side question failed")
            }
        case .paneAction, .moveToMachine, .diffTurn, .preview, .setQuickActions, .tabState, .tabRowTools, .tabRowToolsSet, .sideChat, .subagentPane, .subagentShown, .processTerminal, .chatTab, .offerOpen, .asksOpen, .asksAnswer, .newChatHere: return await respondToHeader(request)
        case .appAction(let id):
            guard newTab?.omnibar.actions.contains(where: { $0.id == id }) == true, let onAppAction else { return Self.unsupported("app.action") }
            onAppAction(id)
            return AgentPaneReply.success()
        case .editShortcut(let kind): guard let onEditShortcut else { return Self.unsupported("shortcut.edit") }; onEditShortcut(kind); return AgentPaneReply.success()
        case .dictation(let command):
            guard let onDictation else { return AgentPaneReply.failure(code: "unsupported", message: "Dictation is unavailable") }
            onDictation(command)
            return AgentPaneReply.success()
        case .dictationRecordingUpload(let path): return await AgentPaneDictationUpload.respond(path, in: self)
        case .dictationRecordingCancel(let path): return AgentPaneDictationUpload.cancel(path, in: self)
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
        case .featureTips(let tips): return featureTipState(tips)
        case .remoteControl(let on): return await AgentPaneRemoteControl.reply(on: on, in: self, userGesture: userGesture)
        case .toolCard(let card, let action, let value): return AgentPaneToolCard.respond(card: card, action: action, value: value, in: self)
        case .computerUsePreview(let action): return AgentPaneComputerUsePreview.respond(action, in: self)
        case .upload(let files): return await AgentPaneUpload.respond(files, in: self)
        case .uploadStage(let stage):
            // A chat with no session yet (a new chat, the New Tab page) stages too: its stager says
            // whether it can take one. Refusing it as unsupported told the page this host is too old
            // to stream, so a recording over the one-frame size failed with Retry (#28647).
            guard let stager = onUploadStage?() else { return Self.unsupported("chat.upload.stage") }
            if case .begin(_, _, let batchToken, _) = stage, batchToken == nil, !transport.gestures.consume() { return Self.transportFailure(.gestureRequired) }
            return await stager(stage, sessionId)
        case .unsupported(let method): return Self.unsupported(method)
        }
    }

    /// The page's chat became session `id` (it started, or the quick panel moved it); no longer a new tab page.
    func adoptSession(_ id: String) {
        guard id != sessionId else { return }
        if sessionId != nil { droppedPaths.clearForSessionChange() }
        sessionId = id
        newTab = nil
        onQuestionKeySessionChange?()
        onSessionChange?(id)
    }

    func setTabRowTools(_ tools: [PaneTabRowTool]) {
        guard tabRowTools != tools else { return }
        tabRowTools = tools
    }

    func setCheckpointAvailable(_ available: Bool) {
        guard checkpointAvailable != available else { return }
        checkpointAvailable = available
        onCheckpointAvailability?(available)
    }
}
