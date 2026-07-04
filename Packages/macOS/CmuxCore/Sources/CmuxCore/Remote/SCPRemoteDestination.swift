import Foundation

/// Formats an SSH destination for scp's `host:path` remote-target syntax.
///
/// `ssh` accepts a bare IPv6 destination, but `scp local host:path` splits the
/// remote target on the first colon, so a bare IPv6 host such as
/// `2001:db8::5:/path` is misparsed. The host must be bracketed
/// (`[2001:db8::5]:/path`), matching ssh's own `[ipv6]` form.
public struct SCPRemoteDestination: Equatable, Sendable {
    /// SSH destination (`user@host` or `host`) before scp-specific bracketing.
    public let destination: String

    /// Creates an scp destination formatter for an SSH destination.
    ///
    /// - Parameter destination: SSH destination (`user@host` or `host`).
    public init(_ destination: String) {
        self.destination = destination
    }

    /// The `[user@]host` portion of an scp destination with a bare IPv6 host bracketed.
    ///
    /// A `user@` prefix and an already-bracketed host are preserved; IPv4
    /// addresses and hostnames pass through untouched.
    public var bracketedDestination: String {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return destination }

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

        let trimmedHost = hostPart.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostNeedsBrackets = !trimmedHost.isEmpty &&
            trimmedHost.contains(":") &&
            !trimmedHost.hasPrefix("[") &&
            !trimmedHost.hasSuffix("]")
        guard hostNeedsBrackets else {
            return trimmed
        }
        let bracketedHost = "[\(hostPart)]"
        guard let userPart else { return bracketedHost }
        return "\(userPart)@\(bracketedHost)"
    }

    /// Builds an scp remote target (`host:path`) for a remote path.
    ///
    /// - Parameter remotePath: Remote path appended after scp's `host:` separator.
    /// - Returns: A remote target safe for scp argument parsing.
    public func remoteTarget(remotePath: String) -> String {
        "\(bracketedDestination):\(remotePath)"
    }
}

extension WorkspaceRemoteConfiguration {
    /// Destination formatter for scp uploads using this configuration's SSH destination.
    public var scpRemoteDestination: SCPRemoteDestination {
        SCPRemoteDestination(destination)
    }

    /// Builds an scp remote target (`host:path`) using this configuration's SSH destination.
    ///
    /// - Parameter remotePath: Remote path appended after scp's `host:` separator.
    /// - Returns: A remote target safe for scp argument parsing.
    public func scpRemoteTarget(remotePath: String) -> String {
        scpRemoteDestination.remoteTarget(remotePath: remotePath)
    }
}
