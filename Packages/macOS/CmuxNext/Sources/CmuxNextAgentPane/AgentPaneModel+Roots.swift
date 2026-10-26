import Foundation

/// The folders a pane's frames may name (``AcpmuxPathPolicy``) and where a new chat starts.
extension AgentPaneModel {
    /// The host's own roots for ``AcpmuxPathPolicy``: the workspace's local tab folders, the
    /// handshake's cwd and the new tab page's cwd.
    func roots() -> [String] {
        var roots = (chosenFolder.map { [$0] } ?? []) + (workspaceRoots?() ?? [])
        if let handshakeCwd { roots.append(handshakeCwd) }
        // The store's start folder is where the chat runs, so it is a root (cx-9aps), while it
        // is still current (``AgentPaneStartFolders/current(of:)``).
        if let folder = startFolders.current(of: self), !roots.contains(folder) { roots.append(folder) }
        if let cwd = newTab?.cwd { roots.append(cwd) }
        return roots
    }

    /// The new tab page's project scan and open folders: roots only when the user picks one.
    func gestureRoots() -> [String] {
        guard let newTab else { return [] }
        return newTab.projects + newTab.omnibar.folders
    }

    /// The pane's workspace root: what a `session/new` without a cwd gets.
    /// Never the home folder or above it: an inherited or default `~` (a fresh workspace's New Tab
    /// page, a terminal at `~`) would widen the page's reach to the whole home folder; the chat
    /// starts in the workspace's next folder, else its agent-home.
    /// An agent-home folder (a terminal the user moved there) is no workspace folder either: the
    /// chat still starts in agent-home, and the page still offers Choose Folder….
    func primaryRoot() -> String? {
        // The store's answer when it gave one (cx-9aps): a real folder, else agent-home (nil).
        if startFolders.answer != nil { return chosenFolder ?? startFolders.current(of: self) }
        // Compatibility only (a daemon without workspace-agent-start-v1). Remove with cx-6bf9.
        let candidates = [handshakeCwd, chosenFolder] + (workspaceRoots?() ?? []).map(Optional.some) + [newTab?.cwd]
        return candidates.lazy.compactMap { $0 }.first { !isHomeOrAbove($0) && !isAgentHome($0) }
    }

    /// Whether `path` is in an agent-home folder: this workspace's base, else the standard one.
    /// Agent-home is only the folder of agent chats (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE).
    func isAgentHome(_ path: String) -> Bool {
        (workspaceAgentHome?()?.home ?? AgentHome.standard)?.contains(path) == true
    }

    /// The chat's folder as the start of another tab (a terminal or split opened from the chat,
    /// #16620). An agent-home folder never leaves the chat: agent-home is never a terminal's
    /// folder and never the workspace's folder. For it the tab gets no folder, and the daemon's
    /// new-terminal resolver decides (NEW-TERMINAL-INHERITS-CWD, cx-zld: the workspace's last
    /// focused terminal, else the spawn default, the home folder for an app launch).
    public func folderForOtherTabs(_ cwd: String?) -> String? {
        guard let cwd, !isAgentHome(cwd) else { return nil }
        return cwd
    }

    /// The chat's exact folder, the one a terminal opened from it inherits (Cmd-D, Cmd-T, Cmd-N,
    /// the header's Terminal, a shell block's Open in Terminal): the folder acpmux reported for the
    /// chat's session, else the one the chat starts in. Read without asking the page, so a
    /// terminal made in the key's frame gets it too. Nil for agent-home (``folderForOtherTabs(_:)``).
    public var terminalFolder: String? {
        let session = sessionId.flatMap(transport.sessions.folder(of:))
        return folderForOtherTabs(session ?? pickedFolder ?? chosenFolder ?? startFolders.current(of: self) ?? handshakeCwd)
    }

    /// Keeps a `workspace.useFolder` pick as the terminal folder (Ctrl-` before the first send,
    /// #22225) when the chat may start there: an `ok` for a folder that is a root of this pane, or
    /// one the person's click granted. A page script's pick of any other folder moves nothing.
    func notePicked(_ reply: [String: Any]) async -> [String: Any] {
        guard let value = reply["value"] as? [String: Any], value["status"] as? String == "ok",
              let cwd = value["cwd"] as? String else { return reply }
        // The reply to the person's click waits for it.
        let canonical = await Task.detached(priority: .userInitiated) { AcpmuxPathPolicy.canonical(cwd) }.value
        let allowed = transport.roots() + transport.addedRoots
        // An agent-home pick replaces an earlier project: it gives no terminal folder (``folderForOtherTabs(_:)``).
        if isAgentHome(cwd) || allowed.contains(cwd) || canonical.map(allowed.contains) == true { pickedFolder = cwd }
        return reply
    }

    /// "Choose Folder…" (`workspace.chooseFolder`): the native sheet only after a real gesture (it
    /// spends the gesture's grant credit), then the pick as the folder of this pane's new chats.
    func chooseFolder() async -> [String: Any] {
        guard let onChooseFolder else { return Self.unsupported("workspace.chooseFolder") }
        guard transport.gestures.consume() else { return Self.transportFailure(.gestureRequired) }
        switch await onChooseFolder() {
        case .chosen(let folder):
            chosenFolder = folder
            pickedFolder = nil
            return AgentPaneReply.success(["cwd": folder])
        case .cancelled:
            return AgentPaneReply.success()
        case .unavailable(let message):
            return AgentPaneReply.failure(code: AgentPaneFolderChoice.unavailableCode, message: message)
        }
    }

    /// Choose Folder… for a chat whose folder is missing (cx-nn3e.1): the sheet only after a real
    /// gesture; a resumable chat comes back as the adopt the page resumes in this pane.
    func chooseChatFolder() async -> [String: Any] {
        guard let needed = seed?.folderNeeded, onChooseChatFolder != nil || Self.chatFolderChooser != nil else {
            return Self.unsupported("chat.folder.choose")
        }
        guard transport.gestures.consume() else { return Self.transportFailure(.gestureRequired) }
        let result: AgentPaneChatFolderResult
        if let onChooseChatFolder { result = await onChooseChatFolder(needed.chat) }
        else if let chooser = Self.chatFolderChooser { result = await chooser(self, needed.chat) }
        else { result = .cancelled }
        switch result {
        case .adopt(let adopt, let cwd):
            seed?.folderNeeded = nil
            if let cwd { handshakeCwd = cwd }
            var value: [String: Any] = ["adopt": adopt.reply]
            if let cwd { value["cwd"] = cwd }
            return AgentPaneReply.success(value)
        case .opened:
            seed?.folderNeeded = nil
            return AgentPaneReply.success(["opened": true])
        case .needsFolder(let reason):
            seed?.folderNeeded = AgentPaneFolderNeeded(chat: needed.chat, reason: reason)
            return AgentPaneReply.success(["reason": reason])
        case .cancelled:
            return AgentPaneReply.success()
        }
    }

    /// Whether `path` is the user's home folder (``AgentPaneTransport/homeFolder``) or above it.
    func isHomeOrAbove(_ path: String) -> Bool {
        AgentHome.isHomeOrAbove(path, home: transport.homeFolder)
    }

}
