import CmuxNextDictation
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
    /// The page switched to or created `sessionId`; the host keeps it so a
    /// reload or relaunch of the pane shows the same session.
    case persistSession(String)
    /// Reads the unsent composer text for a durable session.
    case readDraft(String)
    /// Stores or clears the unsent composer text for a durable session.
    case writeDraft(String, text: String)
    /// A settled transcript scroll's frame intervals in milliseconds, at
    /// most ``maximumPacingFrames``; returns the native display interval and rate mode.
    case framePacing([Double])
    /// Applies the page's adaptive rate decision; fixed-rate panes ignore it.
    case renderRate(Bool)
    /// The new tab page chose a terminal or browser: replace the tab with
    /// one, running or opening `text` (a command, a URL or a search), a
    /// terminal in `cwd` when the page picked a folder.
    case openTab(AgentPaneTabKind, text: String, cwd: String? = nil, search: Bool = false, run: Bool = true)
    /// The command typed after `!` so far, whole each time, while the
    /// terminal that replaces the page is being made (`tab.typeAhead`).
    case typeAhead(String)
    /// Shell mode (`!` first in the composer or the new tab field): run
    /// `command` in `cwd` (``AgentPaneShell``); answers `{id}`. Only with a
    /// real gesture in the pane.
    case shellRun(command: String, cwd: String?)
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
    case rememberNewTab(agent: String)
    /// The new tab page got its first user input (`newTab.touched`); a
    /// touched page is never recycled into the prewarm pool.
    case touched
    /// The identified New Tab field mounted and took DOM focus.
    case newTabInputReady(String)
    /// The location bar picked an open tab or workspace: go there.
    case jump(AgentPaneJumpTarget, id: String)
    /// The new tab page asked to change a kind's New shortcut.
    case editShortcut(AgentPaneTabKind)
    /// The new tab page's "default: X" toggle: what Cmd-T opens
    /// (`tabs.newTabKind`; the App checks the value).
    case setDefaultKind(String)
    /// The new tab page asked the app to run a user facing action.
    case runAction(String)
    /// The new-tab project picker asked for the explicit Browse… fallback.
    case browseProject
    /// "Choose Folder…" (`workspace.chooseFolder`): the native folder sheet that sets the
    /// workspace's agent folder, after a real gesture (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE).
    case chooseFolder
    /// Returns bounded recent project paths for the new-tab picker.
    case listProjects(String?)
    /// The empty-chat action opens the existing onboarding project/history import flow.
    case importAndSync
    /// The new-tab omnibar invoked a host-owned action id.
    case appAction(String)
    /// The chat header's tools and "..." menu: run app action `id` (one of
    /// ``AgentPaneModel/headerActions``) on this chat's tab, a split in `cwd`
    /// when given.
    case paneAction(String, cwd: String? = nil)
    /// The chat tab's state the header's menu labels read: `{pinned}`.
    case tabState
    /// The page reports whether repository checkpoint actions are available so
    /// native palette actions can stay capability-gated with the pane.
    case checkpointAvailability(Bool)
    /// `pane.painted`: the document drew its first frame after the handshake
    /// (once per document).
    case painted
    /// The composer's mic: `dictation.toggle`, `.start`, `.stop`, `.cancel`,
    /// or `dictation.openSettings` with `{permission}`.
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
    /// `git.diff` or `git.status` with `{cwd, …}`: the changes view's reads of
    /// the session's repository, which the App runs on the session host.
    case git(AgentPaneGitRequest)
    /// `git.diff` or `git.status` whose params the bridge refused (no
    /// absolute `cwd`, an unknown scope); answered `native.invalid_request`.
    case invalidGit(String)
    /// Reads the selected local session's GitHub `origin` for Markdown reference links.
    case githubRepository(cwd: String)
    /// `turn.undo`: the edited-files card's host revert (AgentPaneTurnUndo.swift).
    case turnUndo(AgentPaneTurnUndo)
    /// `turn.undo` whose params break its contract; nothing is read or written.
    case invalidTurnUndo
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
    /// The ACP inspector's export (JSON Lines, at most
    /// ``maximumLogBytes`` UTF-8 bytes) to save where the user picks, under
    /// `suggestedName` (a plain file name ending in `.jsonl`).
    case saveLog(text: String, suggestedName: String)
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
    /// Longest composer draft persisted by the native bridge.
    public static let maximumDraftText = 1_000_000

    /// The page keeps about 2M characters of wire log; JSON escaping and
    /// multi-byte text can grow that, but not past this.
    public static let maximumLogBytes = 16 * 1024 * 1024

    /// The save panel's name when the page sends none or an unusable one.
    public static let defaultLogName = "acp.jsonl"

    /// `name` as a plain `.jsonl` file name: path separators and control
    /// characters removed, at most 120 characters, ``defaultLogName`` when
    /// nothing usable is left.
    static func logFileName(_ name: String?) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: (name ?? "").unicodeScalars.filter { scalar in
            scalar != "/" && scalar != ":" && scalar != "\\" && !CharacterSet.controlCharacters.contains(scalar)
        })
        let cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
        var base = cleaned.hasSuffix(".jsonl") ? String(cleaned.dropLast(6)) : cleaned
        base = String(base.prefix(114))
        while base.hasPrefix(".") { base.removeFirst() }
        return base.isEmpty ? defaultLogName : base + ".jsonl"
    }

    public static let handlerName = "agentSession"

    /// A shell run's id as ``AgentPaneShell`` mints them.
    static func shellID(_ params: [String: Any]?) -> String? {
        guard let id = params?["id"] as? String, !id.isEmpty, id.utf8.count <= 64 else { return nil }
        return id
    }
}
