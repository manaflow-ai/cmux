/// Invalid saved connection data, with no credential content in errors.
public enum MobileRemoteProfileError: Error, Equatable, Sendable {
    /// Profile ID is missing.
    case emptyID
    /// Destination is missing.
    case emptyHost
    /// Port is outside the usable TCP/UDP range.
    case invalidPort(Int)
    /// UDP interval is outside the valid port range.
    case invalidUDPRange
    /// A profile cannot use itself as its SSH jump host.
    case selfReferentialJumpHost
    /// Environment name is not a shell identifier.
    case invalidEnvironmentKey
    /// An environment value contains a NUL byte.
    case invalidEnvironmentValue
    /// A host is a literal address or name, not a URL or command.
    case invalidHost
    /// Usernames must be nonempty and contain no control characters.
    case invalidUsername
}
