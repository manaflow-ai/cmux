import CmuxMobileSupport
import CmuxMobileToast

extension Toast {
    /// One capsule for every connection-status notice: newer states replace
    /// the visible one in place instead of queueing a parade.
    static let connectionStatusKey = "connection.status"

    static func connectionReconnecting() -> Toast {
        .info(
            L10n.string("mobile.recovery.reconnecting", defaultValue: "Reconnecting…"),
            systemImage: "arrow.triangle.2.circlepath",
            coalescingKey: Self.connectionStatusKey
        )
    }

    static func connectionUnavailable(
        reconnect: @escaping @MainActor @Sendable () -> Void
    ) -> Toast {
        .failure(
            L10n.string(
                "mobile.connection.toast.unavailableMessage",
                defaultValue: "The live connection dropped. Your Mac may still be online."
            ),
            title: L10n.string("mobile.connection.unavailable", defaultValue: "Disconnected"),
            action: Toast.Action(
                label: L10n.string("mobile.workspace.reconnect", defaultValue: "Reconnect"),
                handler: reconnect
            ),
            coalescingKey: Self.connectionStatusKey
        )
    }

    static func connectionLost(
        retry: @escaping @MainActor @Sendable () -> Void
    ) -> Toast {
        .failure(
            L10n.string(
                "mobile.recovery.lostDescription",
                defaultValue: "Retry to restore live terminal updates."
            ),
            title: L10n.string("mobile.recovery.lost", defaultValue: "Connection lost"),
            action: Toast.Action(
                label: L10n.string("mobile.recovery.retry", defaultValue: "Retry"),
                handler: retry
            ),
            coalescingKey: Self.connectionStatusKey
        )
    }

    static func connectionReauthRequired(
        message: String?,
        signOut: (@MainActor @Sendable () -> Void)?
    ) -> Toast {
        .failure(
            message ?? L10n.string(
                "mobile.recovery.accountMismatch",
                defaultValue: "This computer is signed in to a different cmux account. Sign out and sign back in with that account."
            ),
            autoDismiss: .never,
            action: signOut.map { signOut in
                Toast.Action(
                    label: L10n.string(
                        "mobile.recovery.switchAccount",
                        defaultValue: "Sign Out & Switch Account"
                    ),
                    handler: signOut
                )
            },
            coalescingKey: Self.connectionStatusKey
        )
    }

    static func connectionReconnected() -> Toast {
        .success(
            L10n.string(
                "mobile.connection.reconnectedToast",
                defaultValue: "Reconnected to your Mac."
            ),
            coalescingKey: Self.connectionStatusKey
        )
    }
}

enum ConnectionRecoveryToastPhase: Equatable {
    case reauth(message: String?)
    case lost
    case recovering
    case idle

    static func derive(
        requiresReauth: Bool,
        recoveryFailed: Bool,
        isRecovering: Bool,
        connectionError: String?
    ) -> Self {
        if requiresReauth {
            return .reauth(message: connectionError)
        }
        if recoveryFailed {
            return .lost
        }
        if isRecovering {
            return .recovering
        }
        return .idle
    }
}
