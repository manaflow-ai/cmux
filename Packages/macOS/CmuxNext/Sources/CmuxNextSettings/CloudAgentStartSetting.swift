/// The person's delegation of agents' Cloud starts, in cmux.json:
///
/// ```jsonc
/// "cloud": { "agentsStartWithoutAsking": true }
/// ```
///
/// On by default (Leo, 2026-11-03, on the Start card an agent's `cmux cloud start-chat` raised:
/// "shouldn't have needed to ask me"): an agent's start creates or takes the machine and starts the
/// session with no card, and an agent may answer Start on a card already open. The Cloud plan's own
/// limits still apply (the server's refusal). Off: an agent's `cmux cloud start-session` shows a
/// Start / Not now card in its chat, and only the person's Start (on the card, or `cmux agents
/// dialog answer` from their own terminal) starts anything. Only the person sets it
/// (``SettingsSchema/agentRefusedKeys``): an agent's write is refused, and a managed preference
/// (docs/mdm) may still turn it off.
public nonisolated struct CloudAgentStartSetting: Sendable {
    public static let path = ["cloud", "agentsStartWithoutAsking"]
    public static var key: String { path.joined(separator: ".") }

    /// Agents start Cloud sessions without asking unless the person turned it off.
    public static let defaultValue = true

    public init() {}

    /// Whether agents' Cloud starts run without asking; a missing or non-boolean value is the default, on.
    public func delegated(in root: JSONValue) -> Bool {
        root.value(at: Self.path)?.boolValue ?? Self.defaultValue
    }

    static var descriptors: [SettingDescriptor] {
        [
            SettingDescriptor(
                path, section: .machines, group: SettingsText.keyed("settings.group.cloudWorkspaces", "Cloud Workspaces"),
                title: SettingsText.keyed("settings.cloud.agentsStartWithoutAsking", "Let Agents Start Cloud Sessions Without Asking"),
                help: SettingsText.keyed("settings.cloud.agentsStartWithoutAsking.help",
                                         "An agent's `cmux cloud start-session` creates or resumes the Cloud machine and starts its session with no Start card in the chat. Only you can turn this on."),
                kind: .toggle, default: .bool(Self.defaultValue),
                keywords: ["cloud", "vm", "machine", "agent", "start", "session", "ask", "approve", "permission", "without asking", "delegate"]
            ),
        ]
    }
}
