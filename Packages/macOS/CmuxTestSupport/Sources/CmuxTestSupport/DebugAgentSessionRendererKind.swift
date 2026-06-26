#if DEBUG
/// The renderer a Debug-menu agent-session opener requests.
///
/// `AppDelegate.openDebugAgentSessionReact(_:)` and
/// `openDebugAgentSessionSolid(_:)` differ only in which renderer the new agent
/// session uses. ``DebugTerminalActionsCoordinator`` owns that React-vs-Solid
/// dispatch; it names this package-local kind, and the app target maps it onto
/// its own `AgentSessionRendererKind` when it actually creates the surface,
/// since that app type cannot cross the package boundary. The two cases mirror
/// the legacy `.react` / `.solid` selector split byte-for-byte.
public enum DebugAgentSessionRendererKind: Sendable {
    /// The React agent-session renderer (legacy `openDebugAgentSessionReact`).
    case react

    /// The Solid agent-session renderer (legacy `openDebugAgentSessionSolid`).
    case solid
}
#endif
