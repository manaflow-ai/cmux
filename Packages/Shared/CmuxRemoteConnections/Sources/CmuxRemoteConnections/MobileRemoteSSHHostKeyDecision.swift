/// A trust decision for the exact key observed on the current SSH handshake.
public enum MobileRemoteSSHHostKeyDecision: Equatable, Sendable {
    /// Allow authentication; persistent trust is managed by the approver.
    case accept
    /// Close the handshake without loading credentials.
    case reject
}
