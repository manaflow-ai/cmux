public import Foundation

/// A read-only projection for a remote host's details surface.
///
/// SSH is the transport used to reach a machine. Codex Desktop enrollment is
/// a separate capability and must never be inferred from an SSH connection or
/// from a request being accepted locally. The projection is deliberately a
/// value type so the sidebar/details UI can render it without owning a
/// connection, credential, or enrollment client.
public struct RemoteHostVisibilityProjection: Hashable, Sendable {
    /// The SSH transport state shown independently of Codex enrollment.
    public enum SSHState: Hashable, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case failed(String)

        public var accessibleLabel: String {
            switch self {
            case .disconnected: return "SSH disconnected"
            case .connecting: return "SSH connecting"
            case .connected: return "SSH connected"
            case .reconnecting: return "SSH reconnecting"
            case .failed(let reason):
                let detail = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "SSH failed" : "SSH failed: \(detail)"
            }
        }
    }

    /// A server acknowledgement that proves one exact host registration.
    /// A local request, login, or SSH connection is not a receipt.
    public struct RegistrationReceipt: Hashable, Sendable {
        public let machineID: String
        public let attemptID: String
        public let hostID: String
        public let acceptedAt: Date

        public init(machineID: String, attemptID: String, hostID: String, acceptedAt: Date) {
            self.machineID = machineID
            self.attemptID = attemptID
            self.hostID = hostID
            self.acceptedAt = acceptedAt
        }
    }

    /// Evidence supplied by an enrollment controller. It contains no
    /// transport or credential operations; the projection only interprets it.
    public enum RegistrationEvidence: Hashable, Sendable {
        case notAttempted
        case pending(attemptID: String, startedAt: Date)
        case rejected(statusCode: Int, message: String, occurredAt: Date)
        case accepted(RegistrationReceipt)
    }

    public enum BlockedReason: Hashable, Sendable {
        case mfaRequired(statusCode: Int, message: String)
        case unavailable(statusCode: Int, message: String)
        case unlinked
        case invalidReceipt

        public var accessibleLabel: String {
            switch self {
            case .mfaRequired(_, let message):
                let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "MFA required" : "MFA required: \(detail)"
            case .unavailable(let statusCode, let message):
                let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "unavailable (HTTP \(statusCode))" : "unavailable (HTTP \(statusCode)): \(detail)"
            case .unlinked: return "host is not linked"
            case .invalidReceipt: return "exact enrollment receipt is missing or mismatched"
            }
        }
    }

    /// The explicit registration lifecycle shown in host details.
    public enum RegistrationState: Hashable, Sendable {
        case notAttempted
        case pending(attemptID: String)
        case enrolled(RegistrationReceipt)
        case blocked(reason: BlockedReason)
        case stale(RegistrationReceipt)

        public var accessibleLabel: String {
            switch self {
            case .notAttempted: return "Codex Desktop not enrolled"
            case .pending: return "Codex Desktop enrollment pending"
            case .enrolled(let receipt): return "Codex Desktop enrolled as \(receipt.hostID)"
            case .blocked(let reason): return "Codex Desktop enrollment unavailable: \(reason.accessibleLabel)"
            case .stale: return "Codex Desktop enrollment stale"
            }
        }
    }

    public let hostLabel: String
    /// Nil means the UI cannot safely join this record to a registered machine.
    public let machineID: String?
    public let ssh: SSHState
    public let registration: RegistrationState

    public init(hostLabel: String, machineID: String?, ssh: SSHState, registration: RegistrationState) {
        self.hostLabel = hostLabel
        self.machineID = machineID
        self.ssh = ssh
        self.registration = registration
    }

    /// Projects the latest transport state and the latest durable enrollment
    /// evidence. A receipt is enrolled only when all exact identity fields
    /// match the current host and expected attempt, and only until its age
    /// exceeds `staleAfter`.
    public static func make(
        hostLabel: String,
        machineID: String?,
        ssh: SSHState,
        expectedAttemptID: String? = nil,
        evidence: RegistrationEvidence = .notAttempted,
        now: Date = Date(),
        staleAfter: TimeInterval = 15 * 60
    ) -> Self {
        let registration: RegistrationState
        guard let machineID else {
            registration = .blocked(reason: .unlinked)
            return Self(hostLabel: hostLabel, machineID: nil, ssh: ssh, registration: registration)
        }

        switch evidence {
        case .notAttempted:
            registration = .notAttempted
        case .pending(let attemptID, _):
            registration = .pending(attemptID: attemptID)
        case .rejected(let statusCode, let message, _):
            if statusCode == 403 {
                registration = .blocked(reason: .mfaRequired(statusCode: statusCode, message: message))
            } else {
                registration = .blocked(reason: .unavailable(statusCode: statusCode, message: message))
            }
        case .accepted(let receipt):
            guard receipt.machineID == machineID,
                  expectedAttemptID == nil || expectedAttemptID == receipt.attemptID,
                  !receipt.hostID.isEmpty else {
                registration = .blocked(reason: .invalidReceipt)
                break
            }
            let age = now.timeIntervalSince(receipt.acceptedAt)
            registration = age > staleAfter ? .stale(receipt) : .enrolled(receipt)
        }
        return Self(hostLabel: hostLabel, machineID: machineID, ssh: ssh, registration: registration)
    }

    /// A compact label suitable for VoiceOver and host-details rows. It keeps
    /// the two capabilities visibly distinct, e.g. "Huge Blue, SSH connected,
    /// Codex Desktop enrollment unavailable: MFA required".
    public var accessibleLabel: String {
        "\(hostLabel), \(ssh.accessibleLabel), \(registration.accessibleLabel)"
    }

    /// Maps the app's existing SSH reducer status into this presentation model.
    public static func sshState(_ status: SSHConnectionMachine.Status) -> SSHState {
        switch status {
        case .offline: return .disconnected
        case .connecting: return .connecting
        case .connected: return .connected
        case .reconnecting: return .reconnecting
        case .authFailed(let reason), .hostKeyUntrusted(let reason), .unreachable(let reason): return .failed(reason)
        case .needsInstall(let need): return .failed(String(describing: need))
        case .installing: return .connecting
        case .installFailed(let reason), .failed(let reason), .sessionInUse(let reason): return .failed(reason)
        }
    }
}
