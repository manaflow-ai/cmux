import Foundation

// Canonical scp remote-target formatting for remote configurations.
//
// `ssh` accepts a bare IPv6 destination, but `scp local host:path` splits the
// remote target on the FIRST colon, so a bare IPv6 host such as
// `2001:db8::5:/path` is misparsed: scp silently falls back to a local copy or
// reports "Connection closed", and the upload never reaches the host. The host
// must be bracketed (`[2001:db8::5]:/path`), exactly as ssh's own `[ipv6]`
// form. These are static members because they format a raw destination string
// before (or independent of) a configuration value, and they live on
// `WorkspaceRemoteConfiguration` because that is the domain type that owns the
// `destination` vocabulary. Shared by the daemon-bootstrap upload, the
// drag-and-drop upload, and the detected-SSH drop path so every scp entrypoint
// brackets identically (https://github.com/manaflow-ai/cmux/issues/4948,
// https://github.com/manaflow-ai/cmux/issues/6353).
extension WorkspaceRemoteConfiguration {
    /// Builds an scp remote target (`host:path`) from a destination and remote
    /// path, bracketing a bare IPv6 host so scp's `host:path` parser does not
    /// mistake the address's own colons for the path separator.
    ///
    /// A `user@` prefix and an already-bracketed host are preserved; IPv4
    /// addresses and hostnames (no colon in the host) pass through untouched,
    /// so non-IPv6 destinations format exactly as before.
    public static func scpRemoteTarget(destination: String, remotePath: String) -> String {
        "\(scpBracketedDestination(destination)):\(remotePath)"
    }

    /// Returns the `[user@]host` portion of an scp destination with a bare IPv6
    /// host literal bracketed. See ``scpRemoteTarget(destination:remotePath:)``.
    public static func scpBracketedDestination(_ destination: String) -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return destination }

        // ssh separates `[user@]host` on the first `@`; the host alone is what
        // needs bracketing (a username never contains a colon).
        let parts = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let userPart: String?
        let hostPart: String
        if parts.count == 2 {
            userPart = String(parts[0])
            hostPart = String(parts[1])
        } else {
            userPart = nil
            hostPart = trimmed
        }

        guard hostIsUnbracketedIPv6Literal(hostPart) else {
            return trimmed
        }
        let bracketedHost = "[\(hostPart)]"
        guard let userPart else { return bracketedHost }
        return "\(userPart)@\(bracketedHost)"
    }

    /// True when `host` is a bare (unbracketed) IPv6 literal: it contains a
    /// colon — which a hostname or IPv4 address never does — and is not already
    /// wrapped in `[...]`.
    private static func hostIsUnbracketedIPv6Literal(_ host: String) -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedHost.isEmpty &&
            trimmedHost.contains(":") &&
            !trimmedHost.hasPrefix("[") &&
            !trimmedHost.hasSuffix("]")
    }
}
