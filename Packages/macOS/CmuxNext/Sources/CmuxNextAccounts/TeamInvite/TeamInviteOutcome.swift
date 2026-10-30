/// What cmux.com answered for one invite request: the invitations it sent
/// and the addresses it refused (`already_member`, `invite_failed`).
public nonisolated struct TeamInviteOutcome: Sendable, Equatable {
    /// One pending invitation cmux.com emailed.
    public struct Invitation: Sendable, Equatable {
        /// The invitation id.
        public var id: String
        /// The address it went to.
        public var email: String
        /// The role it grants.
        public var role: String
        /// When it expires (ISO 8601, as cmux.com gave it).
        public var expiresAt: String

        /// Creates an invitation row.
        public init(id: String, email: String, role: String, expiresAt: String) {
            self.id = id
            self.email = email
            self.role = role
            self.expiresAt = expiresAt
        }
    }

    /// One address cmux.com did not invite, with its reason code.
    public struct Failure: Sendable, Equatable {
        /// The address.
        public var email: String
        /// `already_member` or `invite_failed`.
        public var code: String

        /// Creates a failure row.
        public init(email: String, code: String) {
            self.email = email
            self.code = code
        }
    }

    /// The invitations sent.
    public var invitations: [Invitation]
    /// The addresses refused.
    public var failed: [Failure]

    /// Creates an outcome.
    public init(invitations: [Invitation], failed: [Failure] = []) {
        self.invitations = invitations
        self.failed = failed
    }
}
