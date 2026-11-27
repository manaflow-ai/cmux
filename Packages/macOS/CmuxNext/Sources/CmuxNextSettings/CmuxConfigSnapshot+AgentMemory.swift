extension CmuxConfigSnapshot {
    /// `agents.memory.enabled` in the effective settings (the file plus managed
    /// policy): on only when the key is `true`, as one flat key or nested, the
    /// flat key first, the key forms the index tool (`optchat-chief
    /// agent-memory`, settings.rs) accepts. Any other value, or none, leaves it
    /// off: memory reads the user's memory files.
    public var agentMemoryEnabled: Bool {
        let value = root["agents.memory.enabled"] ?? root.value(at: ["agents", "memory", "enabled"])
        return value == .bool(true)
    }
}
