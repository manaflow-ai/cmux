import Foundation

/// The folders a pane's frames may name (``AcpmuxPathPolicy``) and where a new chat starts.
extension AgentPaneModel {
    /// The host's own roots for ``AcpmuxPathPolicy``: the workspace's local tab folders, the
    /// handshake's cwd and the new tab page's cwd.
    func roots() -> [String] {
        var roots = (chosenFolder.map { [$0] } ?? []) + (workspaceRoots?() ?? [])
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
    /// Never the home folder or above it: an inherited or default `~` (a fresh workspace's New Tab
    /// page, a terminal at `~`) would widen the page's reach to the whole home folder; the chat
    /// starts in the workspace's next folder, else its agent-home.
    /// An agent-home folder (a terminal the user moved there) is no workspace folder either: the
    /// chat still starts in agent-home, and the page still offers Choose Folder….
    func primaryRoot() -> String? {
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
    /// folder and never the workspace's folder.
    public func folderForOtherTabs(_ cwd: String?) -> String? {
        guard let cwd, isAgentHome(cwd) else { return cwd }
        // Temporary: remove when NEW-TERMINAL-INHERITS-CWD (cx-zld) lands; then the shared resolver
        // decides. Until then a terminal with no cwd starts in the daemon's own working folder (`/`
        // for a Dock launch), so the terminal gets the home folder, its normal default.
        return transport.homeFolder
    }

    /// "Choose Folder…" (`workspace.chooseFolder`): the native sheet only after a real gesture (it
    /// spends the gesture's grant credit), then the pick as the folder of this pane's new chats.
    func chooseFolder() async -> [String: Any] {
        guard let onChooseFolder else { return Self.unsupported("workspace.chooseFolder") }
        guard transport.gestures.consume() else { return Self.transportFailure(.gestureRequired) }
        switch await onChooseFolder() {
        case .chosen(let folder):
            chosenFolder = folder
            return AgentPaneReply.success(["cwd": folder])
        case .cancelled:
            return AgentPaneReply.success()
        case .unavailable(let message):
            return AgentPaneReply.failure(code: AgentPaneFolderChoice.unavailableCode, message: message)
        }
    }

    /// Whether `path` is the user's home folder (``AgentPaneTransport/homeFolder``) or above it.
    func isHomeOrAbove(_ path: String) -> Bool {
        AgentHome.isHomeOrAbove(path, home: transport.homeFolder)
    }
}
