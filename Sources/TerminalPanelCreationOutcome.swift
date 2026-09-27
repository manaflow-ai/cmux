import Foundation

/// Outcome of a terminal split/surface creation request in a workspace that may
/// route the mutation to Cloud or a remote tmux mirror instead of mutating locally.
///
/// Socket/CLI handlers need to distinguish "the request became a tmux command
/// and the panel arrives asynchronously via the mirror's topology events"
/// (`routedToRemote`) from a genuine failure: reporting an error for a routed
/// request makes automation retry and duplicate remote tmux panes even though
/// the first request already mutated the remote session.
enum TerminalPanelCreationOutcome {
    /// A local panel or a reserved native remote panel was created synchronously.
    case created(TerminalPanel)
    /// The request was forwarded to its remote owner. Its local panel arrives
    /// asynchronously after creation or the mirror's topology event.
    case routedToRemote
    /// Nothing was created or routed.
    case failed

    /// Whether the action was handled, so callers must not issue a fallback create.
    /// Acceptance does not mean the remote terminal is already usable.
    var isAccepted: Bool {
        if case .failed = self { return false }
        return true
    }

    /// The created panel, or `nil` for `.routedToRemote` / `.failed`.
    /// Convenience for callers that only need the nil-vs-panel distinction
    /// (e.g. the `newTerminalSplit` / `newTerminalSurface` wrappers).
    var panel: TerminalPanel? {
        if case .created(let p) = self { return p }
        return nil
    }
}
