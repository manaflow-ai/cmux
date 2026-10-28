import CmuxNextActions

extension CloudHandlers {
    /// Move to Cloud and Bring Back Local: the palette, the tab and chat right-click
    /// menus and `cmux cloud move` / `cmux cloud bring-back` each run one binding
    /// (``CloudMove``, ``CloudBringBack``). An agent's run of either is never a move.
    static func bindMove(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let reason: @MainActor () -> String? = { services.machines.isFeatureDisabled(.cloud) ? RefusalStrings.turnedOffByOrganization : nil }
        // An agent's run asks the person in its chat instead (``CloudMoveAsks``); the card's Move runs this action as theirs.
        services.cloud.toolCards.view = { [weak services] tab, make in make ? services?.agentTabs.view(for: tab) : services?.agentTabs.existingView(tab) }
        // A moved chat's file requests for this Mac ask in that chat (``CloudAccessAsks``).
        services.cloud.accessAsks.start(services: services)
        // A move a quit left unfinished says so in its chat, with Retry (``CloudMoveAsks``).
        services.cloud.moveAsks.offerUnfinished(services: services)
        // Files the person drops or pastes into a moved chat go to its machine (``CloudUploads``); in a
        // chat of an ssh peer's acpmux, to that peer (``AgentPeerUploads``); in a chat on this Mac,
        // files the composer can't attach are saved here (``AgentChatUploads``).
        services.agentTabs.uploader = { [weak services] tab in
            services.flatMap {
                $0.cloud.uploads.uploader(tab: tab, services: $0) ?? AgentPeerUploads.uploader(tab: tab, services: $0)
                    ?? AgentChatUploads.uploader(tab: tab, services: $0)
            }
        }
        services.agentTabs.uploadStager = { [weak services] tab in
            services.flatMap {
                $0.cloud.uploads.stager(tab: tab, services: $0)
                    ?? AgentPeerUploads.stager(tab: tab, services: $0)
                    ?? AgentChatUploads.stager(tab: tab, services: $0)
            }
        }
        // Files dropped or pasted from Finder into a chat on this Mac go as their own paths, never a
        // copy (``AgentPaneDroppedPaths``); a moved or peer chat's still go to its machine. A New Tab page
        // answers as the chat it starts: its tab's record names this Mac's acpmux, or another
        // machine's, whose page model refuses first (``AgentPaneModel/remoteChat``).
        services.agentTabs.localPaths = { [weak services] tab in
            guard let services else { return false }
            return services.cloud.uploads.uploader(tab: tab, services: services) == nil && AgentPeerUploads.target(tab: tab, services: services) == nil
                && services.agentTabs.gitLink?(tab)?.isLocal == true
        }
        bind(CloudMove.action, registry, reason: reason) { invocation in
            if CloudMoveAsks.isAgent(invocation) { return try services.cloud.moveAsks.ask(invocation, services: services) }
            try CloudMove(services: services).start(invocation, context: context)
        }
        bind(CloudBringBack.action, registry, reason: reason) { invocation in
            guard !CloudMoveAsks.isAgent(invocation) else { throw ActionFailure(message: CloudMoveAskStrings.bringBackIsPersons) }
            try CloudBringBack(services: services).start(invocation, context: context)
        }
    }
}
