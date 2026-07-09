extension String {
    /// Whether this remote-connection error detail describes a failure that is
    /// confined to the local daemon proxy / SSH relay transport rather than the
    /// remote host itself.
    ///
    /// The workspace uses this to keep a proxy-only failure from tearing down a
    /// live SSH terminal: when the only thing that broke is the proxy, the
    /// remote session is still usable, so the sidebar surfaces a proxy-only
    /// error instead of a hard disconnect. Matches the legacy
    /// `Workspace.isProxyOnlyRemoteError(_:)` substring set, case-insensitively.
    public var indicatesProxyOnlyRemoteError: Bool {
        let lowered = lowercased()
        return lowered.contains("remote proxy")
            || lowered.contains("proxy_unavailable")
            || lowered.contains("local daemon proxy")
            || lowered.contains("proxy failure")
            || lowered.contains("daemon transport")
    }
}
