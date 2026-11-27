/// `appearance.agentGlow` in cmux.json: off by default, so the window background looks the way
/// `appearance.*` asks for and nothing reacts to agents. On, the window background stays calm while
/// agents are idle and takes a soft glow in the machine's color when an agent needs you. It only
/// adds the glow and never changes the `appearance.*` values, so turning it off restores the
/// usual look.
public nonisolated struct AgentGlowSetting {
    public nonisolated init() {}
}
