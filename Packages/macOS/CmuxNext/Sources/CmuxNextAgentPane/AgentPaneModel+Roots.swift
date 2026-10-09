import Foundation

/// The folders a pane's frames may name (``AcpmuxPathPolicy``) and where a new chat starts.
extension AgentPaneModel {
    /// The host's own roots for ``AcpmuxPathPolicy``: the workspace's local tab folders, the
    /// handshake's cwd and the new tab page's cwd.
    func roots() -> [String] {
        var roots = (chosenFolder.map { [$0] } ?? []) + (workspaceRoots?() ?? [])
        if let handshakeCwd { roots.append(handshakeCwd) }
        // The store's start folder is where the chat runs, so it is a root (cx-9aps), while it
        // is still current (``currentStartFolder``).
        if let folder = currentStartFolder(), !roots.contains(folder) { roots.append(folder) }
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
        if startFolder != nil { return chosenFolder ?? currentStartFolder() }
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

    /// `workspace.useFolder` (cx-nn3e): a folder the user picked for a chat, before any chat starts
    /// there. A project folder is used at once (`ok`; a folder outside every root still passes the
    /// relay on the user's click). The home folder is asked about first (`confirm`, reason `home`):
    /// an agent there can read all of it, and macOS asks for Photos, Documents and more. The
    /// answer (`confirm`) spends its click's gesture and makes the home folder a root, so the chat
    /// starts there at once. `/` and the folders above the home folder are refused (reason `root`).
    func useFolder(_ path: String, confirm: Bool) async -> [String: Any] {
        let homeFolder = transport.homeFolder
        // The store's rules when the daemon has them (cx-9aps): it names the folder or why not.
        if let resolveStartFolder, let answer = await resolveStartFolder(path) {
            if answer.kind == .seed, let cwd = answer.cwd { return AgentPaneReply.success(["status": "ok", "cwd": cwd]) }
            switch answer.skipped?.reason {
            case .home:
                // Granted only when the pick is this Mac's own home folder, checked here again:
                // never a fallback, and never a folder a symlink points at after the store's check.
                let (picked, home) = await Task.detached {
                    (AcpmuxPathPolicy.canonical(path), homeFolder.flatMap(AcpmuxPathPolicy.canonical))
                }.value
                guard let home, picked == home else { return Self.transportFailure(.pathInvalid) }
                return answerHome(home, confirm: confirm)
            case .aboveHome: return AgentPaneReply.success(["status": "refused", "reason": "root", "cwd": path])
            case .agentHome: return AgentPaneReply.success(["status": "ok", "cwd": answer.agentHome ?? path])
            case .missing, nil: return Self.transportFailure(.pathInvalid)
            }
        }
        // Compatibility only (a daemon without workspace-agent-start-v1). Remove with cx-6bf9.
        let (canonical, home) = await Task.detached {
            (AcpmuxPathPolicy.canonical(path).flatMap { AcpmuxPathPolicy.isDirectory($0) ? $0 : nil },
             homeFolder.flatMap(AcpmuxPathPolicy.canonical))
        }.value
        guard let folder = canonical else { return Self.transportFailure(.pathInvalid) }
        guard AgentHome.isHomeOrAbove(folder, home: home) else { return AgentPaneReply.success(["status": "ok", "cwd": folder]) }
        guard let home, folder == home else { return AgentPaneReply.success(["status": "refused", "reason": "root", "cwd": folder]) }
        return answerHome(home, confirm: confirm)
    }

    /// The home folder the user picked: asked about first; the answer (on its click) makes it a
    /// root of this pane, so the chat starts there at once.
    private func answerHome(_ home: String, confirm: Bool) -> [String: Any] {
        if transport.addedRoots.contains(home) { return AgentPaneReply.success(["status": "ok", "cwd": home]) }
        guard confirm else { return AgentPaneReply.success(["status": "confirm", "reason": "home", "cwd": home]) }
        guard transport.gestures.consume() else { return Self.transportFailure(.gestureRequired) }
        transport.grant(home)
        return AgentPaneReply.success(["status": "ok", "cwd": home])
    }

    /// The store's start folder while it is still current: a seed (the pane's own proposal), or a
    /// folder the workspace still has (its agent folder or a tab's folder). A folder the workspace
    /// dropped after the handshake is no root and no fill.
    func currentStartFolder() -> String? {
        guard let startFolder, let folder = startFolder.folder else { return nil }
        if startFolder.kind == .seed { return folder }
        return (workspaceRoots?() ?? []).contains(folder) ? folder : nil
    }

    /// Whether `path` is the user's home folder (``AgentPaneTransport/homeFolder``) or above it.
    func isHomeOrAbove(_ path: String) -> Bool {
        AgentHome.isHomeOrAbove(path, home: transport.homeFolder)
    }
}
