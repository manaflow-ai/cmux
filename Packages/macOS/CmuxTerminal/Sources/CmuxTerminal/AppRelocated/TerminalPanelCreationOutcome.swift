import CmuxPanes
import Foundation

/// Outcome of a terminal split/surface creation request in a workspace that may
/// route the mutation to a remote tmux mirror instead of mutating locally.
///
/// Socket/CLI handlers need to distinguish "the request became a tmux command
/// and the panel arrives asynchronously via the mirror's topology events"
/// (`routedToRemote`) from a genuine failure: reporting an error for a routed
/// request makes automation retry and duplicate remote tmux panes even though
/// the first request already mutated the remote session.
enum TerminalPanelCreationOutcome {
    /// A local panel was created synchronously.
    case created(TerminalPanel)
    /// The request was forwarded to the remote tmux session backing this
    /// mirror workspace. No local panel exists yet — it arrives via the
    /// mirror's `%layout-change` / `%window-add` handling.
    case routedToRemote
    /// Nothing was created or routed.
    case failed

    /// The created panel, or `nil` for `.routedToRemote` / `.failed`.
    /// Convenience for callers that only need the nil-vs-panel distinction
    /// (e.g. the `newTerminalSplit` / `newTerminalSurface` wrappers).
    var panel: TerminalPanel? {
        if case .created(let p) = self { return p }
        return nil
    }
}
