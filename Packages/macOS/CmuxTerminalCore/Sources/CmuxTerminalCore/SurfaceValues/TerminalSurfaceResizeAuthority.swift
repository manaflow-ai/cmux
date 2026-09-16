/// The host that decides when view geometry may update drawable and PTY sizes.
///
/// Surfaces hold this authority weakly and read it synchronously on the main
/// actor. The host owns the phase; adapters do not maintain copied resize flags.
@MainActor
public protocol TerminalSurfaceResizeAuthority: AnyObject {
    /// Whether view-driven sizing must wait for the host's final geometry commit.
    var isRendererResizeDeferred: Bool { get }
}
