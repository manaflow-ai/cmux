/// Where a chat page is shown when it is not a pane tab. The page reads it
/// from the handshake's `surface` field and lays itself out for it.
public nonisolated enum AgentPaneSurface: String, Codable, Sendable {
    /// The Quick Agent Chat panel: a compact composer floating over any app.
    case quick
}
