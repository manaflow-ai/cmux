nonisolated extension DeepLink {
    /// Where a clicked link came from, which bounds what opening it may do (media safety R8,
    /// leo-workspace#874 attack A5). Model output is text an agent wrote, maybe steered by
    /// something it read, so its links only show what is already open.
    public nonisolated enum Origin: Sendable, Hashable {
        /// The person's own surfaces: Open Link…, a pasted link, the OS URL handler, the CLI and
        /// MCP, a link the app itself drew. The link has its full effect.
        case person
        /// Rendered model output: an agent's reply or tool output in a chat, an agent-message
        /// card, the Chief's transcript. The link only reveals what is open (``Effect/revealOnly``).
        case modelOutput
    }

    /// What opening a link may do.
    public nonisolated enum Effect: Sendable, Hashable {
        /// Show the target only when it is already open; nothing is reopened or created.
        case revealOnly
        /// Show the target, else reopen it (a closed tab from Recently Closed) or create it (a
        /// session's agent chat tab).
        case revealOrOpen
    }
}

nonisolated extension DeepLink.Target {
    /// A target's kind without its ids: one per case, so every kind has an effect for each origin.
    public nonisolated enum Kind: Sendable, Hashable, CaseIterable {
        case workspace, pane, tab, session, chiefSession, agent, legacyWorkspace, legacyPane, legacySurface
    }

    /// This target's kind.
    public var kind: Kind {
        switch self {
        case .workspace: .workspace
        case .pane: .pane
        case .tab: .tab
        case .session: .session
        case .chiefSession: .chiefSession
        case .agent: .agent
        case .legacyWorkspace: .legacyWorkspace
        case .legacyPane: .legacyPane
        case .legacySurface: .legacySurface
        }
    }

    /// What opening this target may do for a link from `origin`.
    public func effect(for origin: DeepLink.Origin) -> DeepLink.Effect {
        switch origin {
        case .person: kind.personEffect
        case .modelOutput: kind.modelOutputEffect
        }
    }
}

nonisolated extension DeepLink.Target.Kind {
    /// A person's link: a closed tab reopens and a session no tab shows gets a chat tab; every
    /// other kind only reveals (a pane or workspace that is gone has nothing to reopen, and an
    /// agent or Chief subagent link never starts or resumes a session).
    var personEffect: DeepLink.Effect {
        switch self {
        case .tab, .session: .revealOrOpen
        case .workspace, .pane, .chiefSession, .agent, .legacyWorkspace, .legacyPane, .legacySurface: .revealOnly
        }
    }

    /// A link in model output reveals only. Each kind is listed, so a new one has to choose.
    var modelOutputEffect: DeepLink.Effect {
        switch self {
        case .workspace, .pane, .tab, .session, .chiefSession, .agent, .legacyWorkspace, .legacyPane, .legacySurface: .revealOnly
        }
    }
}
