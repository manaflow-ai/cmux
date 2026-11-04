// `cmux cloud start-session` (Lawrence: "start new VMs from acp chat"): take a
// Cloud machine (or create a named one), start an agent session in that
// machine's own acpmux, and answer `{machine_id, session_id, host}`. Titles
// live in CloudSessionActions.xcstrings; the handler is CloudStartSession.swift.

nonisolated enum CloudSessionActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        var start = ActionDescriptor(
            id: "cloudStartSession",
            title: String(localized: "action.cloudStartSession", defaultValue: "Start Agent Session on Cloud Machine…", table: "CloudSessionActions", bundle: .module),
            description: "Starts an agent session (--agent claude, codex, ...) in the Cloud machine's own acpmux and returns machine_id, session_id and host, plus the chat tab's workspace_id and surface_id. Name the machine with --target machine:<id>, or --name <name> to take or create it; --cwd is the folder there. --login pass|machine|none: your login, the machine's own, or none (default: the machine's login or your earlier choice). An agent's run asks no one (unless cloud.agentsStartWithoutAsking is off). A slow run answers pending: true; run it again for its session.",
            keywords: ["vm", "cloud", "agent", "session", "chat", "acp", "acpmux", "start", "claude", "codex"], category: .cloud, symbol: "sparkles",
            surfaces: [.palette, .contextMenu], arguments: [agent, name, cwd, login], targets: [.machine], cliName: "cloud start-session",
            surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ActionSurfaceCatalog.p(.cloudMachine, .connection, 221, folder: .connection)])
        )
        // An agent's run waits for the person's Start on its chat's card, then for the session.
        start.waitsForPerson = true
        // cmuxterm-hq#7086: the relay-first chat. The prompt goes over HTTPS to the platform and down the socket
        // the machine holds from boot, so the first reply never waits for this Mac's link to the machine.
        var relay = ActionDescriptor(
            id: "cloudRelayChat",
            title: String(localized: "action.cloudRelayChat", defaultValue: "Chat on Cloud Machine over the Relay…", table: "CloudSessionActions", bundle: .module),
            description: "Sends --prompt to --agent (claude, codex, ...) on a Cloud machine (--target machine:<id>) over the machine's relay, with no link to the machine, and answers when the turn ends: session_id (the machine's acpmux session), reply, stop_reason, first_text_ms and total_ms. A turn still running after 35 s answers what came so far with ended: false and goes on in that session while the app runs. delivered: false means the prompt never reached the machine (no machine took it, or the relay refused it). --cwd is the folder there; --prompt-id makes a resend run once.",
            keywords: ["vm", "cloud", "agent", "chat", "relay", "prompt", "claude", "codex"], category: .cloud, symbol: "bubble.left.and.text.bubble.right",
            surfaces: [.palette], arguments: [agent, prompt, cwd, promptID], targets: [.machine], cliName: "cloud relay-chat",
            surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .pointerMenuTrim)
        )
        // The CLI waits for the turn's answer (or what came of it within CloudHandlers.answerWithin).
        relay.waitsForResult = true
        return [start, relay]
    }

    /// `--prompt`: what the relay chat sends.
    static var prompt: ActionArgument {
        ActionArgument(name: "prompt", title: String(localized: "argument.cloudRelayChat.prompt", defaultValue: "Prompt", table: "CloudSessionActions", bundle: .module),
                       kind: .string)
    }

    /// `--prompt-id`: the caller's id for the prompt; acpmux runs one id once.
    static var promptID: ActionArgument {
        ActionArgument(name: "prompt-id", title: String(localized: "argument.cloudRelayChat.promptID", defaultValue: "Prompt ID", table: "CloudSessionActions", bundle: .module),
                       kind: .string, isRequired: false)
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

    /// `--login pass|machine|none`: the harness login the machine gets (CloudHarnessLoginAsk).
    static var login: ActionArgument {
        ActionArgument(name: "login", title: String(localized: "argument.cloudStartSession.login", defaultValue: "Harness Login", table: "CloudSessionActions", bundle: .module),
                       kind: .string, isRequired: false)
    }
}
