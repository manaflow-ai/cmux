/// A backend device-token registration failure safe to expose in UI and logs.
public enum PushRegistrationFailure: Error, Sendable, Equatable {
    /// The native session could not supply a valid access/refresh token pair.
    case authenticationRequired
    /// Account deletion currently blocks user-scoped mutations.
    case accountDeletionInProgress
    /// The server asked the client to wait before retrying.
    case rateLimited(retryAfterSeconds: Int?)
    /// The account already has the maximum number of unpruned device tokens.
    case deviceLimitReached(limit: Int)
    /// The request could not reach the API.
    case networkUnavailable
    /// The API or APNs relay is temporarily unavailable.
    case serviceUnavailable
    /// The configured API base URL is invalid.
    case invalidConfiguration
    /// A successful HTTP response did not contain the registration acknowledgement.
    case invalidServerResponse
    /// The API permanently rejected the registration request.
    case rejected(statusCode: Int)

    /// Whether repeating the same registration later can reasonably succeed.
    public var isRecoverable: Bool {
        switch self {
        case .rateLimited, .networkUnavailable, .serviceUnavailable:
            true
        case .authenticationRequired, .accountDeletionInProgress, .deviceLimitReached,
             .invalidConfiguration, .invalidServerResponse, .rejected:
            false
        }
    }
}

/// The furthest backend stage a push-enabled iOS installation has confirmed.
public enum PushRegistrationBackendState: Sendable, Equatable {
    /// The OS has not supplied an APNs device token yet.
    case awaitingDeviceToken
    /// A cached APNs token exists but has not been acknowledged this launch.
    case registrationRequired
    /// iOS failed to acquire a current APNs token. A user-triggered retry can
    /// call `registerForRemoteNotifications()` again.
    case deviceTokenRegistrationFailed
    /// A device-token request is currently in flight.
    case registering
    /// The API acknowledged the current APNs token.
    case registered
    /// Registration stopped at a typed, user-visible failure.
    case failed(PushRegistrationFailure)

    /// Whether the current state can recover automatically.
    public var isRecoverable: Bool {
        if case let .failed(failure) = self {
            return failure.isRecoverable
        }
        return false
    }
}

/// Truthful local and backend push-registration readiness.
public struct PushRegistrationSnapshot: Sendable, Equatable {
    /// Whether the user explicitly opted into phone notifications.
    public let isEnabled: Bool
    /// Whether this install has acquired an APNs device token.
    public let hasDeviceToken: Bool
    /// The backend acknowledgement stage for the current token.
    public let backendState: PushRegistrationBackendState

    /// Creates a push-registration snapshot.
    ///
    /// - Parameters:
    ///   - isEnabled: Whether the user explicitly opted in.
    ///   - hasDeviceToken: Whether APNs supplied a token.
    ///   - backendState: The furthest confirmed backend stage.
    public init(
        isEnabled: Bool,
        hasDeviceToken: Bool,
        backendState: PushRegistrationBackendState
    ) {
        self.isEnabled = isEnabled
        self.hasDeviceToken = hasDeviceToken
        self.backendState = backendState
    }

    /// The canonical disabled snapshot.
    public static let disabled = PushRegistrationSnapshot(
        isEnabled: false,
        hasDeviceToken: false,
        backendState: .awaitingDeviceToken
    )
}
