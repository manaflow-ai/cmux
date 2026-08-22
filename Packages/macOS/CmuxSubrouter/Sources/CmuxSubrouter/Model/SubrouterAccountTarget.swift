/// The user-selected destination for a new or re-authenticated account.
///
/// A target is deliberately separate from the daemon endpoint: a remote URL
/// is not necessarily a name in `sr`'s server registry, while the CLI's
/// `SUBROUTER_CODEX_SERVER` override needs the registry name to select a
/// server safely for one invocation.
public enum SubrouterAccountTarget: Sendable, Equatable {
    /// Keep the account on this Mac's local Subrouter daemon.
    case local
    /// Upload/manage the account through a named `sr` server entry.
    case server(name: String)
}
