// `cmux cloud start-session` (Lawrence: "start new VMs from acp chat"): take a
// Cloud machine (or create a named one), start an agent session in that
// machine's own acpmux, and answer `{machine_id, session_id, host}`. Titles
// live in CloudSessionActions.xcstrings; the handler is CloudStartSession.swift.

nonisolated enum CloudSessionActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        var start = ActionDescriptor(
            id: "cloudStartSession",
            title: String(localized: "action.cloudStartSession", defaultValue: "Start Agent Session on Cloud Machine…", table: "CloudSessionActions", bundle: .module),
            description: "Starts an agent session (--agent claude, codex, ...) in the Cloud machine's own acpmux and returns machine_id, session_id and host, plus the chat tab's workspace_id and surface_id. Name the machine with --target machine:<id>, or --name <name> to take that machine or create it; --cwd is the folder there. An agent's run asks the person in its chat first. A run still starting after about 3 minutes answers pending: true; the same command again returns its session.",
            keywords: ["vm", "cloud", "agent", "session", "chat", "acp", "acpmux", "start", "claude", "codex"], category: .cloud, symbol: "sparkles",
            surfaces: [.palette, .contextMenu], arguments: [agent, name, cwd], targets: [.machine], cliName: "cloud start-session",
            surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ActionSurfaceCatalog.p(.cloudMachine, .connection, 221, folder: .connection)])
        )
        // An agent's run waits for the person's Start on its chat's card, then for the session.
        start.waitsForPerson = true
        return [start]
    }

    /// `--agent`: the harness to start (`claude`, `codex`, ...), as the machine's acpmux names it.
    static var agent: ActionArgument {
        ActionArgument(name: "agent", title: String(localized: "argument.cloudStartSession.agent", defaultValue: "Agent", table: "CloudSessionActions", bundle: .module),
                       kind: .string)
    }

    /// `--name`: without `--target`, the machine with this name, created when there is none.
    static var name: ActionArgument {
        ActionArgument(name: "name", title: String(localized: "argument.cloudStartSession.name", defaultValue: "Machine Name", table: "CloudSessionActions", bundle: .module),
                       kind: .string, isRequired: false)
    }

    /// `--cwd`: the folder on the machine the session starts in (default: its workspace's folder).
    static var cwd: ActionArgument {
        ActionArgument(name: "cwd", title: String(localized: "argument.cloudStartSession.cwd", defaultValue: "Folder on the Machine", table: "CloudSessionActions", bundle: .module),
                       kind: .string, isRequired: false)
    }
}
