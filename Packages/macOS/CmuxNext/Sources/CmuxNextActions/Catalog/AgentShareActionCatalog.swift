/// Share with Guest (design chat-multiplayer.md 6, hq#4766): one link to one agent chat. `agent.share`
/// is the op every surface runs: the palette's Share Chat with Guest…, the chat tab's menu, `cmux share
/// chat` and its MCP tool. List, revoke and kick are its family (the share sheet offers them in place):
/// the CLI and MCP name them, the palette and menus do not. The handlers are CmuxNextApp's
/// AgentShareHandlers.swift.
nonisolated enum AgentShareActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        var actions: [ActionDescriptor] = [
            ActionDescriptor(
                id: "agent.share",
                title: t("action.agent.share", "Share Chat with Guest…"),
                description: "Makes a guest link to an agent chat (--target tab:<id>, --surface N, else the chat that runs the command, else the focused chat): the guest sees the chat as you do, including command output and the agent's reasoning, and each message they send waits for you. --ttl (seconds, or 30m, 24h, 7d; default 24h) and --uses (1 to 8; default 1). Returns share_id, url (null when no share service is configured), expires_at (ms), uses_left, session and surface. Errors: share.needs_sign_in, share.room_unreachable (try again), share.room_refused, share.not_a_chat, share.limit.",
                keywords: ["share", "guest", "invite", "link", "multiplayer", "agent", "chat", "collaborate"],
                category: .agents, symbol: "person.badge.plus", surfaces: [.palette, .contextMenu],
                arguments: [surfaceArgument, ttlArgument, usesArgument], targets: [.tab], cliName: "share chat",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [
                    // In the tab menu's More (its top level is Chrome's twelve rows, ContextMenuEssentials).
                    ActionSurfaceCatalog.p(.tab, .identity, 590, label: t("action.agent.share.menu", "Share with Guest…")),
                ])
            ),
            ActionDescriptor(
                id: "agent.share.list",
                title: t("action.agent.share.list", "List Guest Links"),
                description: "Lists this Mac's guest links (all, or one chat's with --target tab:<id> or --surface N): shares, each with share_id, state (provisioning, active, revoked, expired, closed), session, surface, expires_at, expires_in_secs, uses_left, room and guests [{guest_id, name, joined_at, state}]. Never a link's secret.",
                keywords: ["share", "guest", "link", "list"], category: .agents, symbol: "list.bullet",
                arguments: [surfaceArgument], targets: [.tab], cliName: "share list", surfacePlan: family
            ),
            ActionDescriptor(
                id: "agent.share.revoke",
                title: t("action.agent.share.revoke", "Revoke Guest Link"),
                description: "Ends a guest link (--share-id from `cmux share list`): it stops working and every guest on it leaves at once. Returns share_id and state.",
                keywords: ["share", "guest", "link", "revoke", "end", "stop"], category: .agents, symbol: "link.badge.minus",
                arguments: [shareIDArgument], cliName: "share revoke", surfacePlan: family
            ),
            ActionDescriptor(
                id: "agent.share.kick",
                title: t("action.agent.share.kick", "Remove Guest"),
                description: "Removes one guest (--share-id and --guest-id from `cmux share list`) from a guest link: their page ends and they cannot join again. Returns share_id, guest_id and state.",
                keywords: ["share", "guest", "remove", "kick"], category: .agents, symbol: "person.badge.minus",
                arguments: [shareIDArgument, guestIDArgument], cliName: "share kick", surfacePlan: family
            ),
        ]
        // A CLI or agent run answers with the link or the shares (AgentShareHandlers).
        for index in actions.indices { actions[index].waitsForResult = true }
        return actions
    }

    /// The share sheet offers list, revoke and kick in place; the CLI and MCP name them.
    static var family: ActionSurfacePlan {
        ActionSurfacePlan(palette: .exempt(.familyMember), cli: .offered, contextMenuExemption: .familyMember)
    }

    static var surfaceArgument: ActionArgument {
        ActionArgument(name: "surface", title: t("argument.agentShare.surface", "Surface"), kind: .int(1...Int(Int32.max)), isRequired: false)
    }

    static var ttlArgument: ActionArgument {
        ActionArgument(name: "ttl", title: t("argument.agentShare.ttl", "Expires After"), kind: .string, isRequired: false)
    }

    static var usesArgument: ActionArgument {
        ActionArgument(name: "uses", title: t("argument.agentShare.uses", "Uses"), kind: .int(1...8), isRequired: false)
    }

    static var shareIDArgument: ActionArgument {
        ActionArgument(name: "shareId", title: t("argument.agentShare.shareId", "Share ID"), kind: .string)
    }

    static var guestIDArgument: ActionArgument {
        ActionArgument(name: "guestId", title: t("argument.agentShare.guestId", "Guest ID"), kind: .string)
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "ActionCatalog", bundle: .module)
    }
}
