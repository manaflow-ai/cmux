/// Explicit authorization required to establish a nested-provider attachment.
///
/// Environment variables and OSC discovery descriptors may prefill a
/// ``NestedAttachmentProposal`` but never authorize attachment by themselves.
public enum NestedAttachmentAuthorization: Hashable, Sendable {
    /// User confirmed attachment through UI (or an equivalent explicit gesture).
    case userConfirmed
    /// An authenticated cmux control-socket caller requested attachment.
    ///
    /// - Parameter requestID: Correlator for audit/debug (not a secret).
    case authenticatedControlSocket(requestID: String)

    /// Whether this value counts as explicit opt-in authority.
    public var isExplicitOptIn: Bool {
        switch self {
        case .userConfirmed, .authenticatedControlSocket:
            return true
        }
    }
}

/// Non-authoritative source that suggested an attachment endpoint.
public enum NestedAttachmentProposalSource: String, Hashable, Codable, Sendable {
    /// Suggested from the terminal launch / inherited environment.
    case environment
    /// Suggested from a bounded OSC discovery descriptor (future PR).
    case oscDescriptor
}
