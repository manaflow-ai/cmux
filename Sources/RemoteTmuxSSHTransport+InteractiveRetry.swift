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
        "command not found",                // bash/zsh: ProxyCommand binary missing
        ": not found",                      // dash/busybox sh: ProxyCommand binary missing
        "no such file or directory",        // shell: ProxyCommand path does not exist
        "exec format error",                // shell: ProxyCommand binary for wrong architecture
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

    /// Whether the bytes a transport produced BEFORE control mode are an unanswered
    /// credential prompt.
    ///
    /// Everything else here reads stderr, which is where ssh reports an auth failure. A transport
    /// that authenticates itself does not report a failure at all: it prints a prompt to its
    /// terminal and waits. cmux gives it pipes, so the prompt lands in the pre-control output and
    /// the stream then sits there until it is torn down — measured against a corporate ssh broker,
    /// which produced a passcode prompt and no error, so the attach failed with nothing to explain
    /// it and the transport's own log stayed empty.
    ///
    /// Matched against the pre-control region only, which is the login banner and prompt before the
    /// first `%begin`, so ordinary pane output cannot reach it. Deliberately generic: the prompt
    /// wording belongs to whatever the site's broker uses, and pinning a vendor's phrasing would
    /// make this stop working the day that changes.
    static func indicatesUnansweredCredentialPrompt(_ preControlOutput: String) -> Bool {
        let haystack = preControlOutput.lowercased()
        // Trailing colon on purpose: these are prompts awaiting input, not prose mentioning them.
        let prompts = [
            "passcode:",
            "password:",
            "verification code:",
            "one-time password:",
            "second factor:",
            "enter a passcode",
            "two-factor",
            "touch your security key",
            "confirm user presence",
        ]
        return prompts.contains { haystack.contains($0) }
    }
}
