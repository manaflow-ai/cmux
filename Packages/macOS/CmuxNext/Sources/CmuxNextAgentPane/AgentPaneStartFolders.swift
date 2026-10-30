public import Foundation

/// One pane's start folder (cx-9aps): the store's answer (`workspace.agent_start.get`) and the
/// rules that use it for the handshake, a folder the user picks (`workspace.useFolder`), the
/// relay's fill and roots. Its own type, so the pane model only forwards to it.
@MainActor
public final class AgentPaneStartFolders {
    /// Asks the store where a new chat starts, with the folder the pane proposes (a seed, the New
    /// Tab page's folder, a pick). Nil, or a nil answer, means a daemon without
    /// workspace-agent-start-v1: the pane then decides as before (compatibility only, removed
    /// with bead cx-6bf9).
    public var resolve: (@MainActor (_ proposed: String?) async -> AgentPaneStartFolder?)?
    /// The store's last answer for this pane's new chat.
    public internal(set) var answer: AgentPaneStartFolder?
    /// The App's saved environments a New Tab page starts a chat with (`environment.*`).
    public var environments: (any AgentPaneEnvironmentStoring)?

    public init() {}

    /// The store's start folder while it is still current: a seed (the pane's own proposal), or a
    /// folder the workspace still has (its agent folder or a tab's folder). A folder the workspace
    /// dropped after the handshake is no root and no fill.
    func current(of model: AgentPaneModel) -> String? {
        guard let answer, let folder = answer.folder else { return nil }
        if answer.kind == .seed { return folder }
        return (model.workspaceRoots?() ?? []).contains(folder) ? folder : nil
    }

    /// The handshake's start folder: the store's answer when the daemon has it (the page shows it;
    /// `startKind`, `chooseFolder` for agent-home), else the pane's own rules (compatibility only,
    /// cx-6bf9). True when the folder was filled in rather than proposed (no root of its own).
    func apply(to handshake: inout AgentPaneHandshake, ready: Bool, model: AgentPaneModel) async -> Bool {
        guard model.sessionId == nil else { return false }
        if let resolve, let answer = await resolve(handshake.cwd) {
            self.answer = answer
            // A reconnect keeps the page's own pick; it learns the start folder only from `ready`.
            // A proposed folder the store skipped (`~`, above it) never reaches the page.
            if ready || answer.kind == .seed || answer.skipped != nil { handshake.cwd = answer.folder }
            handshake.startKind = answer.kind.rawValue
            if answer.kind == .agentHome, model.onChooseFolder != nil { handshake.chooseFolder = true }
            return answer.kind != .seed
        }
        // Compatibility only (a daemon without workspace-agent-start-v1). Remove with cx-6bf9.
        // An inherited or default `~`, or an agent-home folder, is no chat folder (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE).
        var filled = false
        if let cwd = handshake.cwd, model.isHomeOrAbove(cwd) || model.isAgentHome(cwd) { handshake.cwd = nil }
        if ready, handshake.cwd == nil, let root = model.primaryRoot() {
            handshake.cwd = root
            filled = true
        }
        // A new chat with no folder starts in agent-home; the page offers Choose Folder….
        if handshake.cwd == nil, model.primaryRoot() == nil, model.onChooseFolder != nil, model.workspaceAgentHome?() != nil {
            handshake.chooseFolder = true
        }
        return filled
    }

    /// `workspace.useFolder` (cx-nn3e): a folder the user picked for a chat, before any chat starts
    /// there. A project folder is used at once (`ok`), and the person's click makes a folder outside
    /// every root a root (``grantPicked(_:transport:)``). The home folder is asked about first
    /// (`confirm`, reason `home`): an agent there can read all of it, and macOS asks for Photos,
    /// Documents and more. The answer (`confirm`) spends its click's gesture and makes the home
    /// folder a root, so the chat starts there at once. `/` and the folders above the home folder are refused (reason `root`).
    func use(_ path: String, confirm: Bool, transport: AgentPaneTransport) async -> [String: Any] {
        let homeFolder = transport.homeFolder
        // The store's rules when the daemon has them (cx-9aps): it names the folder or why not.
        if let resolve, let answer = await resolve(path) {
            if answer.kind == .seed, let cwd = answer.cwd {
                await Self.grantPicked(cwd, transport: transport)
                return AgentPaneReply.success(["status": "ok", "cwd": cwd])
            }
            // An agent-home folder picked itself (cx-djoj7): the store names it as the chat's.
            if answer.kind == .agentHome, answer.skipped == nil, let home = answer.agentHome {
                return AgentPaneReply.success(["status": "ok", "cwd": home])
            }
            switch answer.skipped?.reason {
            case .home:
                // Granted only when the pick is this Mac's own home folder, checked here again:
                // never a fallback, and never a folder a symlink points at after the store's check.
                let (picked, home) = await Task.detached {
                    (AcpmuxPathPolicy.canonical(path), homeFolder.flatMap(AcpmuxPathPolicy.canonical))
                }.value
                guard let home, picked == home else { return AgentPaneModel.transportFailure(.pathInvalid) }
                return await Self.answerHome(home, confirm: confirm, transport: transport)
            case .aboveHome: return AgentPaneReply.success(["status": "refused", "reason": "root", "cwd": path])
            case .agentHome: return AgentPaneReply.success(["status": "ok", "cwd": answer.agentHome ?? path])
            case .missing, nil: return AgentPaneModel.transportFailure(.pathInvalid)
            }
        }
        // Compatibility only (a daemon without workspace-agent-start-v1). Remove with cx-6bf9.
        let (canonical, home) = await Task.detached {
            (AcpmuxPathPolicy.canonical(path).flatMap { AcpmuxPathPolicy.isDirectory($0) ? $0 : nil },
             homeFolder.flatMap(AcpmuxPathPolicy.canonical))
        }.value
        guard let folder = canonical else { return AgentPaneModel.transportFailure(.pathInvalid) }
        guard AgentHome.isHomeOrAbove(folder, home: home) else {
            await Self.grantPicked(folder, transport: transport)
            return AgentPaneReply.success(["status": "ok", "cwd": folder])
        }
        guard let home, folder == home else { return AgentPaneReply.success(["status": "refused", "reason": "root", "cwd": folder]) }
        return await Self.answerHome(home, confirm: confirm, transport: transport)
    }

    /// A new chat on another machine (cx-1bhjj): that machine's store decides its folder by the
    /// same rules, against its own home folder, so a home or above-home seed never starts there by
    /// itself. Its agent-home folder is this app's to make, so a chat there gets no folder yet.
    func applyRemote(to handshake: inout AgentPaneHandshake, model: AgentPaneModel) async {
        guard model.sessionId == nil, let resolve, let answer = await resolve(handshake.cwd) else { return }
        self.answer = answer
        handshake.cwd = answer.kind == .agentHome ? nil : answer.cwd
    }

    /// `workspace.useFolder` in a chat on another machine: the same answers as on this Mac, from
    /// that machine's store (its home folder is asked about first; `/` and above are refused). A
    /// store without the rules uses the folder; that machine's acpmux still checks it.
    func useRemote(_ path: String, confirm: Bool, transport: AgentPaneTransport) async -> [String: Any] {
        guard let resolve, let answer = await resolve(path) else { return AgentPaneReply.success(["status": "ok", "cwd": path]) }
        switch answer.skipped?.reason {
        case .home:
            // Use Home Folder on that machine: asked first; the answer spends its click's gesture.
            let home = answer.skipped?.cwd ?? path
            if transport.remoteHomeChosen.contains(home) { return AgentPaneReply.success(["status": "ok", "cwd": home]) }
            guard confirm else { return AgentPaneReply.success(["status": "confirm", "reason": "home", "cwd": home]) }
            guard transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
            transport.remoteHomeChosen.insert(home)
            return AgentPaneReply.success(["status": "ok", "cwd": home])
        case .aboveHome: return AgentPaneReply.success(["status": "refused", "reason": "root", "cwd": path])
        case .missing: return AgentPaneModel.transportFailure(.pathInvalid)
        case .agentHome, nil: return AgentPaneReply.success(["status": "ok", "cwd": answer.kind == .seed ? answer.cwd ?? path : path])
        }
    }

    /// A project folder the person picked (hq#2569 item 1): their click on it makes it a root of
    /// this pane, so the chat's start there passes the relay. The gesture it spends (often the
    /// Send's own) goes on to the chat's first prompt (``AgentPaneTransport/grantPicked(_:)``). A
    /// pick with no gesture behind it (page script) grants nothing, and a folder that is already a
    /// root spends nothing.
    private static func grantPicked(_ path: String, transport: AgentPaneTransport) async {
        // The store's spelling is not always the canonical one the relay compares (a symlink).
        guard let folder = await Task.detached(operation: { AcpmuxPathPolicy.canonical(path) }).value,
              transport.gestures.consume() else { return }
        await transport.grantPicked(folder)
    }

    /// The home folder the user picked: asked about first; the answer (on its click) makes it a
    /// root of this pane, so the chat starts there at once.
    private static func answerHome(_ home: String, confirm: Bool, transport: AgentPaneTransport) async -> [String: Any] {
        if transport.addedRoots.contains(home) { return AgentPaneReply.success(["status": "ok", "cwd": home]) }
        guard confirm else { return AgentPaneReply.success(["status": "confirm", "reason": "home", "cwd": home]) }
        guard transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        await transport.grantPicked(home, trust: false)
        return AgentPaneReply.success(["status": "ok", "cwd": home])
    }
}
