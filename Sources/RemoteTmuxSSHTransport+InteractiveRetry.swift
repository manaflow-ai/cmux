extension RemoteTmuxSSHTransport {
    /// Whether a failed `BatchMode=yes` connect failed because the local
    /// `ProxyCommand` closed the transport *silently* before SSH could surface
    /// an explicit auth error string.
    ///
    /// A `ProxyCommand` with its own pre-handshake authentication or 2FA leg
    /// can silently abort under BatchMode because it has no tty to prompt on.
    /// An interactive retry lets that prompt surface. The match is anchored to
    /// OpenSSH's pipe-transport placeholders (`to UNKNOWN port 65535`,
    /// `by UNKNOWN port 65535`) and suppressed when stderr also carries a
    /// diagnostic marker for a non-recoverable proxy failure.
    static func indicatesProxyCommandTransportClosed(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        let hasProxyPlaceholder = lowered.contains("to unknown port 65535")
            || lowered.contains("by unknown port 65535")
        guard hasProxyPlaceholder else { return false }
        return !Self.nonRecoverableProxyMarkers.contains(where: { lowered.contains($0) })
    }

    /// Lowercase substrings that indicate a `ProxyCommand` / `ProxyJump`
    /// closure was not silent, so an interactive ssh retry will not help.
    private static let nonRecoverableProxyMarkers: [String] = [
        "connect failed:",                  // ssh -W target connection refused/timeout
        ": open failed:",                   // channel N: open failed: ...
        "stdio forwarding failed",          // ProxyJump -W teardown
        "port forwarding failed",
        "connection refused",
        "no route to host",
        "network is unreachable",
        "operation timed out",              // BSD/macOS TCP connect timeout
        "connection timed out",             // Linux TCP connect timeout (nc / OpenSSH)
        "could not resolve hostname",       // OpenSSH DNS-resolution wrapper (all OSes)
        "name or service not known",        // Linux getaddrinfo NXDOMAIN
        "nodename nor servname provided",   // BSD/macOS getaddrinfo NXDOMAIN (e.g. ProxyCommand `nc`)
        "temporary failure in name resolution",
        "kex_exchange_identification:",     // target spoke no SSH / closed during key exchange
        "ssh_exchange_identification:",     // target closed during banner exchange
    ]

    /// Convenience predicate composing the recovery rule the controller's
    /// BatchMode-discovery catch sites share: a failure where re-running ssh
    /// interactively will open the shared master and let the next batch probe
    /// succeed.
    ///
    /// All routing sites in ``RemoteTmuxController`` go through one name so a
    /// future recovery signal does not silently regress any catch site that
    /// spelled out only one constituent predicate.
    static func indicatesInteractiveRetryWillHelp(_ stderr: String) -> Bool {
        indicatesAuthRequired(stderr)
            || indicatesProxyCommandTransportClosed(stderr)
    }
}
