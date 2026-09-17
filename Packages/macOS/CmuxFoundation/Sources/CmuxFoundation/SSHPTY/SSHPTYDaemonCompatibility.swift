/// Matches remote daemon identity against the client's release.
public struct SSHPTYDaemonCompatibility: Sendable {
    private let clientVersion: String
    private let allowsDevelopmentFingerprint: Bool

    /// Creates an admission policy for a release.
    /// - Parameters:
    ///   - clientVersion: The version required by this client.
    ///   - allowsDevelopmentFingerprint: Whether a 12-hex dev suffix is accepted.
    public init(clientVersion: String, allowsDevelopmentFingerprint: Bool) {
        self.clientVersion = clientVersion
        self.allowsDevelopmentFingerprint = allowsDevelopmentFingerprint
    }

    /// Returns whether the daemon identifies the same release.
    /// - Parameter daemonVersion: The version from the connected daemon handshake.
    /// - Returns: False for missing identities or malformed development suffixes.
    public func matches(_ daemonVersion: String?) -> Bool {
        guard let daemonVersion, !clientVersion.isEmpty, clientVersion != "dev" else { return false }
        if daemonVersion == clientVersion { return true }
        guard allowsDevelopmentFingerprint else { return false }
        let prefix = clientVersion + "-dev-"
        guard daemonVersion.hasPrefix(prefix) else { return false }
        let fingerprint = daemonVersion.dropFirst(prefix.count)
        return fingerprint.count == 12 && fingerprint.allSatisfy { "0123456789abcdef".contains($0) }
    }
}
