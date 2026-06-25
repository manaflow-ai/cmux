#if DEBUG
/// Which agent-session renderer a Debug menu opener requests.
///
/// The Debug menu has two agent-session openers (React and Solid) that differ
/// only in the renderer they spawn. ``DebugStressWorkspaceDriver`` carries this
/// package-local choice across the ``DebugStressWorkspaceHosting`` seam so it
/// never names the app's own renderer-kind type; the host maps each case onto
/// its live agent-session renderer when creating the surface.
public enum DebugAgentSessionRendererKind: Sendable, Hashable {
    /// The React-based agent-session renderer.
    case react
    /// The Solid-based agent-session renderer.
    case solid
}
#endif
