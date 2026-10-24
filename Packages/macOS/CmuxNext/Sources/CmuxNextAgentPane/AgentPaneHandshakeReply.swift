import Foundation

/// The page's `ready` and `reconnect`: the host's handshake for this pane's session, filled in
/// with its seed, new tab page, start folder and link scheme. Its connection stays on the model
/// until the page's `transport.open`; the reply never encodes it.
@MainActor
enum AgentPaneHandshakeReply {
    static func reply(to request: AgentPaneRequest, in model: AgentPaneModel) async -> [String: Any] {
        // A page that loaded again starts without the tab row: it is offered again.
        if request == .ready { model.tabRow.pageLoaded() }
        model.setCheckpointAvailable(false)
        do {
            var handshake = request == .ready
                ? try await model.host.handshake(sessionId: model.sessionId)
                : try await model.host.reconnectHandshake(sessionId: model.sessionId)
            // Only a chat without a session yet starts from the seed.
            if model.sessionId == nil, let seed = await model.seed?.take() {
                handshake.cwd = seed.cwd
                handshake.draft = seed.draft
                handshake.prompt = seed.prompt
                // A prompt a person's own action seeded goes out by itself with a single-use
                // ticket bound to its promptId (cx-k21v gap 4, chief: person only). The seed hands
                // its prompt out once, so a reload gets neither the prompt nor a ticket again.
                if let prompt = seed.prompt, !prompt.isEmpty, seed.promptBy.sendsBySelf {
                    let issued = model.transport.gestures.issueSeedTicket()
                    handshake.promptTicket = AgentPaneHandshake.PromptTicket(promptId: issued.promptId, ticket: issued.ticket)
                }
                handshake.harness = seed.harness
                if seed.showsHarnesses { handshake.harnesses = true }
                (handshake.adopt, handshake.pastTurns) = (seed.adopt, await AgentPanePastTurn.turns(of: seed.pastChat))
            }
            // The surface holds after the chat has a session (a reload
            // of the quick panel stays compact).
            handshake.surface = model.seed?.surface
            // A chat opened for its workspace gets its context until it has a session (cx-ihyx2).
            // A chat on another machine does not: its remote wire carries only the prompt text.
            if model.sessionId == nil, model.seed?.workspaceContext == true, handshake.connection?.remote == nil {
                handshake.workspaceContext = true
            }
            // A new tab page is a new chat on every host, the mock included: the page
            // never falls back to the most recent session behind it. Its chat starts in
            // the page's folder unless a seed named one.
            if model.sessionId == nil, let newTab = model.newTab {
                handshake.newTab = newTab
                handshake.newSession = true
                if handshake.cwd == nil { handshake.cwd = newTab.cwd }
            }
            if model.sessionId == nil, let folderNeeded = model.seed?.folderNeeded { handshake.folderNeeded = AgentPaneHandshake.FolderNeeded(reason: folderNeeded.reason) }
            handshake.linkScheme = model.linkScheme
            // A chat on another machine names that machine (its host set it), never this Mac.
            if handshake.machineName == nil { handshake.machineName = await AgentPaneModel.localMachineName?.value }
            // A pane attaches only to the exact session its tab recorded: a session the
            // daemon lacks (gone, or a recreated daemon's) shows "This chat isn't
            // available", never another chat (P1 2026-10-09).
            if model.sessionId != nil { handshake.sessionMustExist = true }
            // A chat its host already started (on another machine) gets no new-chat folder steps:
            // they read this Mac's folders and disk (cx-k21v).
            let started = handshake.connection?.remote != nil
            if started { await model.startFolders.applyRemote(to: &handshake, model: model) }
            let filled = started ? false : await model.startFolders.apply(to: &handshake, ready: request == .ready, model: model)
            if !started { handshake.githubRepository = await AgentPaneGitHubRepository.read(at: handshake.cwd) }
            handshake.revealTurn = model.pendingRevealTurn
            model.pendingRevealTurn = nil
            // Only a fresh page reads it; a reconnect keeps it for the page's own ready.
            if request == .ready {
                // A relaunched chat's chips: their contents are read now, off the main thread, not at launch (#17587).
                if let pending = model.pendingWake, pending.kept != nil {
                    let read = await pending.readingBack()
                    if model.pendingWake == pending { model.pendingWake = read }
                }
                handshake.wake = model.pendingWake
                (model.handedWake, model.pendingWake) = (model.pendingWake, nil)
            }
            model.hasHandshake = true
            // A filled-in folder stays the workspace's, no root of its own (cx-9aps).
            if let cwd = handshake.cwd, !filled { model.handshakeCwd = cwd }
            if let session = handshake.sessionId { model.transport.sessions.add(session) }
            if handshake.connection?.remote != nil { model.remoteChat = true }
            // The connection stays here; the reply never encodes it.
            model.pendingConnection = handshake.connection
            model.transport.acpmuxSocket = handshake.connection?.remote == nil ? handshake.connection?.socketPath : nil
            model.transport.acpmuxExecutable = handshake.connection?.remote == nil ? handshake.connection?.executable : nil
            handshake.connection = nil
            return AgentPaneReply.handshake(handshake)
        } catch {
            let message = AgentPaneHostError.userMessage(for: error)
            var reply = AgentPaneReply.failure(code: "host_unavailable", message: message)
            // A refused chat of another machine still names that machine on its chip (cx-k21v).
            if let machine = (error as? any AgentPaneHostRefusal)?.machineName, var failure = reply["error"] as? [String: Any] {
                failure["details"] = ["machineName": machine]
                reply["error"] = failure
            }
            return reply
        }
    }
}
