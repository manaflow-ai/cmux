/// The person's delegation of agents' Cloud use, in cmux.json:
///
/// ```jsonc
/// "cloud": { "agentsStartWithoutAsking": true }
/// ```
///
/// On by default, like bypassing permissions by default (Leo, 2026-11-03, on the Start card an agent's
/// `cmux cloud start-chat` raised: "shouldn't have needed to ask me"; 2026-11-04, on the "Create a Cloud
/// machine?" card: "Proper toggle akin to how we've been saying 'just auto/bypass permissions by default'
/// and a use can at some point see a cute toggle or checkmark idk if they want"). An agent, the CLI or a
/// script then creates Cloud machines, moves its chat to Cloud and starts sessions there with no card, and
/// an agent may answer Start on a card already open. The Cloud plan's own limits still apply (the server's
/// refusal). Off: each of those asks the person first (the sidebar's "Create a Cloud machine?" card, whose
/// Don't Ask Again switch turns this back on; Move / Not now / Always in the chat; Start / Not now in the
/// chat for `cmux cloud start-session`). Only the person sets it (``SettingsSchema/agentRefusedKeys``): an
/// agent's write is refused, and a managed preference (docs/mdm) may still turn it off.
public nonisolated struct CloudAgentStartSetting: Sendable {
    public static let path = ["cloud", "agentsStartWithoutAsking"]
    public static var key: String { path.joined(separator: ".") }

    /// Agents use Cloud without asking unless the person turned it off.
    public static let defaultValue = true

    public init() {}

    /// Whether agents' Cloud creates, moves and starts run without asking; a missing or non-boolean value is the default, on.
    public func delegated(in root: JSONValue) -> Bool {
        root.value(at: Self.path)?.boolValue ?? Self.defaultValue
    }

    static var descriptors: [SettingDescriptor] {
        [
            SettingDescriptor(
                path, section: .machines, group: SettingsText.keyed("settings.group.cloudWorkspaces", "Cloud Workspaces"),
                title: SettingsText.keyed("settings.cloud.agentsStartWithoutAsking", "Let Agents Use Cloud Without Asking"),
                help: SettingsText.keyed("settings.cloud.agentsStartWithoutAsking.help",
                                         "Agents, `cmux cloud` in a terminal and scripts create Cloud machines, move chats to Cloud and start sessions there with no card asking you first. Your plan's limits still apply. Only you can change this."),
                kind: .toggle, default: .bool(Self.defaultValue),
                keywords: ["cloud", "vm", "machine", "agent", "start", "session", "create", "new machine", "move", "ask", "approve", "permission", "bypass", "without asking", "delegate"]
            ),
        ]
    }
}
