/// Which kind of entrypoint started a sign-in.
public enum SignInEntrypoint: String, Sendable, CaseIterable {
    /// A Sign In button in the app (Settings, sidebar, Cloud gates).
    case app
    /// A sign-in shown inside a pane, which also offers the URL to copy.
    case pane
    /// Account > Switch Account, after its sign-out.
    case switchAccount = "switch_account"
    /// The socket or CLI `auth` sign-in.
    case socket
}
