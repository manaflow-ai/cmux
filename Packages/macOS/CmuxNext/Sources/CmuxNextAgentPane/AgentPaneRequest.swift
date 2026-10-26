import CmuxNextDictation
public import CmuxNextSettings
public import Foundation

/// A request the page posts to `window.webkit.messageHandlers.agentSession`:
/// `{id, method, params}`. Only host-owned methods reach Swift; chat actions
/// run in the page against acpmux.
public nonisolated enum AgentPaneRequest: Equatable, Sendable {
    /// The page loaded and wants the handshake.
    case ready
    /// The page lost its daemon and wants a fresh handshake (a restarted
    /// daemon has a new port and token), without starting one.
    case reconnect
    /// A bounded element report from the debug app-owned webview picker.
    case uiPointerReport(String)
    /// `acpmux.restart {}`: the refusal card's Restart acpmux, after a handshake refused a daemon
    /// another binary runs on this app's socket (``AgentPaneHostError/daemonRefused(holder:socketPath:reason:executable:owner:)``
    /// with an owner): that daemon stops, keeping its sessions, and the page's next handshake
    /// starts this app's own. Only with a real gesture; answers `{stopped}`.
    case restartAcpmux
    /// The page switched to or created `sessionId`; the host keeps it so a
    /// reload or relaunch of the pane shows the same session.
    case persistSession(String)
    /// `chat.missing` with `{session, reason}`: the page says this tab's chat isn't available
    /// (`notListedAtOpen`, `leftListWhileShown`); the host logs it, so the views can be counted.
    case missingChat(session: String, reason: String)
    /// A new chat's typed text before it has a session (`chat.unsentDraft`, cx-z5vd): the App
    /// keeps it with the tab, so a relaunch opens the chat with it.
    case unsentDraft(String)
    /// A settled transcript scroll's frame intervals in milliseconds, at
    /// most ``maximumPacingFrames``; returns the native display interval and rate mode.
    case framePacing([Double])
    /// Applies the page's adaptive rate decision; fixed-rate panes ignore it.
    case renderRate(Bool)
    /// The new tab page chose a terminal or browser: replace the tab with
    /// one, running or opening `text` (a command, a URL or a search), a
    /// terminal in `cwd` when the page picked a folder.
    case openTab(AgentPaneOpenTab)
    /// The command typed after `!` so far, whole each time, while the
    /// terminal that replaces the page is being made (`tab.typeAhead`).
    case typeAhead(String)
    /// Opens a redeemed durable Run attempt's terminal on its enrolled worker (`run.attach`).
    case runAttach(AgentPaneRunAttach)
    /// `run.attach` whose params break its contract or whose endpoint expired; nothing opens.
    case invalidRunAttach
    /// Shell mode (`!` first in the composer or the new tab field): run
    /// `command` in `cwd` (``AgentPaneShell``); answers `{id}`. Only with a
    /// real gesture in the pane.
    case shellRun(command: String, cwd: String?)
    /// `harness.update {id}`: the chat card's Update (cx-1mbnu): this Mac's acpmux runs that agent
    /// CLI's own update now and answers `{ok, version?, error?}`. Only with a real gesture.
    case harnessUpdate(id: String)
    /// `harness.restart {}`: the card's Restart Chat: this chat's agent restarts on the installed
    /// version and resumes (after its turn); answers `{restarted, after_turn}`. Only with a gesture.
    case harnessRestart
    /// `shell.read {id, after}`: the run's output from byte `after`.
    case shellRead(id: String, after: Int)
    /// `shell.stop {id}`: interrupt the run's process group.
    case shellStop(id: String)
    /// `shell.complete {line, cwd}`: Tab in shell mode. `line` is the text before the caret; the
    /// user's own shell lists the candidates (``AgentPaneShellCompletion``). Only with a real
    /// gesture in the pane: completion functions run code.
    case shellComplete(line: String, cwd: String?)
    /// The agent picked on the new tab screen, to remember for the next
    /// new tab (`newTab.remember`).
    case rememberNewTab(AgentPaneRememberedPick)
    /// The new tab page's style switch (`newTab.setTemplate`) or edit mode (`newTab.editWidgets`):
    /// ``AgentPaneNewTabEdit``.
    case editNewTab(AgentPaneNewTabEdit)
    /// The New Tab page player's control (`nowPlaying.command {command, seconds}`).
    case nowPlaying(AgentPaneNowPlaying.Command)
    /// The new tab page got its first user input (`newTab.touched`); a
    /// touched page is never recycled into the prewarm pool.
    case touched
    /// The page's New Tab context at once (`newTab.context`), before the
    /// handshake that waits for acpmux: a cold New Tab page draws its frame
    /// (layout, field, empty list) at first render (cx-0rpl.10).
    case newTabContext
    /// The identified New Tab field mounted and took DOM focus.
    case newTabInputReady(String)
    /// A local page's newest chats as JSON text (`newTab.warm {warm}`): the next New Tab page's
    /// context carries it (``AgentPaneNewTab/warm``), so its first frame lists them.
    case newTabWarm(String)
    /// The location bar picked an open tab or workspace: go there.
    case jump(AgentPaneJumpTarget, id: String)
    /// The new tab page asked to change a kind's New shortcut.
    case editShortcut(AgentPaneTabKind)
    /// The new tab page asked the app to run a user facing action.
    case runAction(String)
    /// The new-tab project picker asked for the explicit Browse… fallback.
    case browseProject
    /// "Choose Folder…" (`workspace.chooseFolder`): the native folder sheet that sets the
    /// workspace's agent folder, after a real gesture (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE).
    case chooseFolder
    /// A folder the user picked for a chat (`workspace.useFolder {cwd, confirm}`, cx-nn3e): the
    /// host answers whether it is used at once, asked about first (the home folder) or refused
    /// (`/`, above the home folder). `confirm` is the user's answer to the question, on its click.
    case useFolder(String, confirm: Bool)
    /// Choose Folder… for a chat whose folder is missing (`chat.folder.choose`, cx-nn3e.1).
    case chooseChatFolder
    /// The summary panel's Attach files or folders (`chat.attach.choose`): the native open panel,
    /// after a real gesture, for a chat on this Mac.
    case chooseAttachments
    /// `chat.attach.dropped {kind, names}`: where on this Mac the files of the person's last native
    /// drop or paste are, for a chat on this Mac (``AgentPaneDroppedPaths``). The names are the
    /// person's files: never logged.
    case attachDropped(AgentPaneDroppedPaths.Kind, names: [String])
    /// Returns bounded recent project paths for the new-tab picker.
    case listProjects(String?)
    /// `project.icon {cwd}`: the project's own favicon for its picker badge, as a small data URL.
    case projectIcon(String)
    /// `chats.open {key}`: a device chat card (`harness:sessionId`) the New Tab page shows,
    /// opened through the app's shared Open Chat path.
    case openChat(String)
    /// `chats.openInTerminal {key}`: Open in Terminal from an All chats row's right-click menu.
    case openChatInTerminal(String)
    /// `chats.watch {key}`: View Only from an All chats row's right-click menu.
    case watchChat(String)
    /// `chats.page {query?, cursor?, limit?}`: one page of the New Tab page's All chats list.
    case chatsPage(AgentPaneChatsQuery)
    /// `environment.list|save|remove`: the New Tab page's saved environments (``AgentPaneEnvironmentRequest``).
    case environment(AgentPaneEnvironmentRequest)
    /// The new-tab omnibar invoked a host-owned action id.
    case appAction(String)
    /// The chat header's tools and "..." menu: run app action `id` (one of
    /// ``AgentPaneModel/headerActions``) on this chat's tab, a split in `cwd`
    /// when given. `toggle` (a quick action's `mode: "toggle"`, acpmux
    /// header/quickActions.ts) closes the split this tab's button opened
    /// when it is still there, else opens one.
    case paneAction(String, cwd: String? = nil, toggle: Bool = false)
    /// The header's Changes or an edited-files card naming a chat turn (`pane.action {id:
    /// "openDiffViewer", cwd, mode, turn}`): the diff beside the chat, with that turn as its Last
    /// turn (``AgentPaneDiffTurn``).
    case diffTurn(AgentPaneDiffTurn, cwd: String?, toggle: Bool)
    /// The header's Preview (`pane.action {id: "preview", url, mode}`): toggles or opens a browser tab
    /// beside the chat on `url`, the local page its last turn started or mentioned. A loopback
    /// address only; a click that closes the open preview may name none.
    case preview(url: String?, toggle: Bool)
    /// The header's right-click menu saved the quick actions (`pane.setQuickActions
    /// {quickActions}`): the App writes them into `agent-pane/layout.json`.
    case setQuickActions([AgentPaneQuickAction])
    /// The chat tab's state the header's menu labels read: `{pinned}`; `refresh` (a turn ended)
    /// asks for the chat folder's pull request again.
    case tabState(refresh: Bool)
    /// `pane.tabRowTools {width}`: the chat header's tools take `width` CSS pixels at the trailing
    /// end of the pane's tab row (``AgentPaneTabRow``), 0 when the page draws none there.
    case tabRowTools(width: Double)
    /// New side chat: open the fork `sessionId` the page just made beside this chat.
    case sideChat(String)
    /// A chat this one made (a fork, a Continue In…), opened at a destination of its own: a tab,
    /// a split, a new workspace or a new window (`placement`; none is a tab).
    case chatTab(String, AgentForkDestination)
    /// `chat.offer.open {sessionId, sender?}`: the person opened a session the chat shows (a
    /// sub-session its agent started, the session that started it, with `sender` the chat that sent
    /// it a message): its tab, else one beside this chat, focused (``AgentPaneOfferOpen``).
    case offerOpen(String, sender: Bool)
    /// `chat.asks.open {sessionId}`: Needs you went to another chat's ask: that chat's tab, else a
    /// new tab beside this chat; never this chat replaced in place (``AgentPaneAskOpen``).
    case asksOpen(String)
    /// `chat.subagentPane {subagent, focus}`: this chat's subagent in an agent pane of its own,
    /// right of the chat (``AgentSubagentPanes``); `focus` moves keyboard focus to it.
    case subagentPane(String, focus: Bool)
    /// `chat.processTerminal {toolCallId}`: the background process this chat's tool call started,
    /// in a read-only terminal tab beside the chat (``AgentPaneProcessViewer``).
    case processTerminal(toolCall: String)
    /// A started chat's New Chat Here: a new chat in that folder, in a tab of its own.
    case newChatHere(String)
    /// The page reports whether repository checkpoint actions are available so
    /// native palette actions can stay capability-gated with the pane.
    case checkpointAvailability(Bool)
    /// `pane.painted`: the document drew its first frame after the handshake
    /// (once per document). `fromKeptTail` is the page's own account of what it
    /// drew there: a chat it took from a kept tail (tailCache.ts), which is
    /// already on screen in that frame, or a chat read cold, which the pane's
    /// loading state fades in. An older page says nothing, which means cold.
    case painted(fromKeptTail: Bool)
    /// The composer's mic: `dictation.toggle`, `.start`, `.stop`, `.cancel`,
    /// `dictation.openSettings` with `{permission}`, or `dictation.audio` with `{enabled}`.
    case dictation(AgentPaneDictationCommand)
    /// `file.open` with `{path, where}`: a changed file from the changes view,
    /// in a tab beside the agent or in the text editor.
    case openFile(path: String, target: AgentPaneFileTarget)
    /// `browser.open` with `{url}`: a turn's local web page (its preview
    /// card), in a browser tab of the pane. Only loopback http(s) pages
    /// (`URL.isAgentPanePreview`); anything else is unsupported.
    case openPreview(URL)
    /// The quick panel's page: Esc hides the panel, keeping its draft.
    case quickDismiss
    /// The quick panel's page: open its chat in the main window and hide
    /// the panel. `{sessionId}` is optional; without it the host uses the
    /// session the page last persisted.
    case quickOpenInWindow(sessionId: String?)
    /// The quick panel's page (Start Agent's Return): its chat started;
    /// hand the session to the sidebar in the background and hide the panel.
    case quickStartInBackground(AgentPaneQuickStart)
    /// The floating chat's page (cx-b9qi): `quick.setOnTop {onTop}` floats the
    /// panel over other windows or not; `quick.setCollapsed {collapsed}` folds it
    /// to its compact bar or opens it again.
    case quickSetOnTop(Bool)
    case quickSetCollapsed(Bool)
    /// `quick.floatingState`: the page, once loaded, reads the floating chat's state.
    case quickFloatingState
    /// `quick.context`: Include focused tab asks what the user is looking at in cmux.
    case quickContext
    /// `git.diff` or `git.status` with `{cwd, …}`: the changes view's reads of
    /// the session's repository, which the App runs on the session host.
    case git(AgentPaneGitRequest)
    /// `git.commit` or `git.push` with `{session_id, …, idempotency_key}`: the
    /// changes view's Commit and Push, which the App runs on the session host.
    case gitWrite(AgentPaneGitWrite)
    /// A git read or write whose params the bridge refused (no absolute
    /// `cwd`, an unknown scope); answered `native.invalid_request`.
    case invalidGit(String)
    /// Reads the selected local session's GitHub `origin` for Markdown reference links.
    case githubRepository(cwd: String)
    /// `turn.undo`: the edited-files card's host revert (AgentPaneTurnUndo.swift).
    case turnUndo(AgentPaneTurnUndo)
    /// `turn.undo` whose params break its contract; nothing is read or written.
    case invalidTurnUndo
    /// `git.stage` / `git.unstage` / `git.stageHunk` / `git.unstageHunk`: the Changes view's Stage
    /// and Unstage, of files or one hunk (AgentPaneGitStage.swift);
    /// nil when its params break the contract, and nothing runs.
    case gitStage(AgentPaneGitStage?)
    /// `git.pullRequest`: the Changes view's Create PR (AgentPaneGitPullRequest.swift); nil when its
    /// params break the contract, and nothing runs.
    case gitPullRequest(AgentPaneGitPullRequest?)
    /// `project.instructions`: the chat menu's Edit CLAUDE.md (AgentPaneProjectInstructions.swift);
    /// nil when its params break the contract.
    case projectInstructions(AgentPaneProjectInstructions?)
    /// `project.addFiles`: the chat menu's Add Files to Project (AgentPaneProjectFiles.swift), with the
    /// same `{cwd, name}`; nil when its params break the contract.
    case projectAddFiles(AgentPaneProjectInstructions?)
    /// `composer.capture` with `{mode}`: the composer's Attach Screenshot… or Attach Window…
    /// (AgentPaneCapture.swift).
    case composerCapture(mode: String?)
    /// `transport.open`: open the host's acpmux socket named by the last handshake
    /// (``AgentPaneTransport``); answers `{connection}` once it is open.
    case transportOpen
    /// `transport.send` with `{connection, frames}`: page frames for the host's socket, checked
    /// against ``AcpmuxPaneMethods``.
    case transportSend(connection: Int, frames: [String])
    /// `transport.close` with `{connection}`.
    case transportClose(connection: Int)
    /// `transport.gesture {intent}`: reserve the user's current gesture for one pick sent later (a
    /// pick held behind a harness switch); answers `{ticket}`. Nil intent: the params break the
    /// contract (``AgentPaneGestureIntent``).
    case transportGesture(AgentPaneGestureIntent?)
    /// `transport.gesture.release`: drop every ticket (the page's harness switch ended or failed).
    case transportGestureRelease
    /// What a reply links to: chips, images, the preview card's browsers (``AgentPaneReplyRequest``).
    case reply(AgentPaneReplyRequest)
    /// `pane.saveLog` (the ACP inspector's export) and `pane.saveFile` (a side panel document):
    /// text to save where the user picks (``AgentPaneSave``).
    case saveFile(AgentPaneSave)
    /// `pane.showContextUsage` or `pane.showDictation` with `{show}`: the composer's Hide or Show
    /// Context Usage, or the mic's Hide dictation button, which the host writes to cmux.json at `path`
    /// (`agentPane.showContextUsage`, `agentPane.showDictation`).
    case composerSetting(path: [String], show: Bool)
    /// `pane.setDisplay {key, value}`: the ··· menu's Text & Width popover writes one `agentPane.display.*`
    /// key (``AgentPaneDisplaySetting/writablePath(_:)``); a null value removes it.
    /// `pane.setAttachmentView {view}` writes `agentPane.attachmentView` the same way (`inline` or `strip`).
    case displaySetting(path: [String], value: JSONValue?)
    /// `chat.toolCard.respond {id, action, value?}`: a click on a button of a tool card (``AgentPaneToolCard``),
    /// with what the person typed in its field.
    case toolCard(card: String, action: String, value: AgentPaneToolCard.Entered?)
    /// `chat.upload {files: [{name, data}]}`: files the person dropped or pasted, for the chat's Cloud machine (``AgentPaneUpload``).
    case upload([AgentPaneUpload])
    case uploadStage(AgentPaneUploadStageRequest)
    case unsupported(String)

    /// Most frames in one `transport.send` (the page sends what one task wrote).
    public static let maximumSendFrames = 4096

    /// A shell mode request: a command can carry secrets and `shell.read` polls, so never logged.
    public var isShell: Bool {
        switch self {
        case .shellRun, .shellRead, .shellStop, .shellComplete: true
        default: false
        }
    }

    /// A tool card answer carrying what the person typed (a secret): never logged, even redacted.
    public var carriesEntered: Bool {
        if case .toolCard(_, _, .some) = self { return true }
        return false
    }

    /// An upload: the person's files, never logged.
    public var carriesFiles: Bool {
        if case .upload = self { return true }
        if case .uploadStage = self { return true }
        return false
    }

    /// A transport request: frequent and carrying chat content, so never logged with its values.
    public var isTransport: Bool {
        switch self {
        case .transportOpen, .transportSend, .transportClose, .transportGesture, .transportGestureRelease: true
        default: false
        }
    }

    public static let maximumPacingFrames = 640
    /// Longest `tab.open` text kept; a command or address is far shorter.
    public static let maximumOpenTabText = 8192
    /// The page keeps about 2M characters of wire log; JSON escaping and
    /// multi-byte text can grow that, but not past this.
    public static let maximumLogBytes = 16 * 1024 * 1024

    public static let handlerName = "agentSession"

    /// A shell run's id as ``AgentPaneShell`` mints them.
    static func shellID(_ params: [String: Any]?) -> String? {
        guard let id = params?["id"] as? String, !id.isEmpty, id.utf8.count <= 64 else { return nil }
        return id
    }
}
