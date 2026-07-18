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
    /// The request entered the serialized daemon mutation queue. This does not
    /// claim RPC acceptance; callers may inspect the request ID while the
    /// canonical projection remains unchanged.
    case submittedToBackend(TerminalBackendTopologyMutationSubmission)
    /// Nothing was created or routed.
    case failed

    /// The created panel, or `nil` for either routed outcome and `.failed`.
    /// Convenience for callers that only need the nil-vs-panel distinction
    /// (e.g. the `newTerminalSplit` / `newTerminalSurface` wrappers).
    var panel: TerminalPanel? {
        if case .created(let p) = self { return p }
        return nil
    }
}

/// Workspace creation either returns the newly allocated local overlay or a
/// stable daemon request whose workspace arrives through canonical projection.
enum WorkspaceCreationOutcome {
    case created(Workspace)
    case submittedToBackend(TerminalBackendTopologyMutationSubmission)
    case failed

    var workspace: Workspace? {
        if case .created(let workspace) = self { return workspace }
        return nil
    }

    var isAccepted: Bool {
        switch self {
        case .created, .submittedToBackend: true
        case .failed: false
        }
    }
}

/// Browser creation is synchronous in embedded mode and canonical/asynchronous
/// when cmuxd owns placement while Swift owns the WKWebView runtime.
enum BrowserPanelCreationOutcome {
    case created(BrowserPanel)
    case submittedToBackend(TerminalBackendTopologyMutationSubmission)
    case failed

    var panel: BrowserPanel? {
        if case .created(let panel) = self { return panel }
        return nil
    }

    var surfaceID: UUID? {
        switch self {
        case .created(let panel): panel.id
        case .submittedToBackend(let submission): submission.surfaceID
        case .failed: nil
        }
    }

    var isAccepted: Bool {
        switch self {
        case .created, .submittedToBackend: true
        case .failed: false
        }
    }
}
