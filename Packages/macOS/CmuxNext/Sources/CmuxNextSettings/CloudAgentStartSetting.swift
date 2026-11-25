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
    public static var key: String { configPath.joined(separator: ".") }

    public init() {}

    /// Whether agents' Cloud creates, moves and starts run without asking; a missing or non-boolean value is the default, on.
    public func delegated(in root: JSONValue) -> Bool {
        root.value(at: Self.configPath)?.boolValue ?? Self.fallback
    }
}
