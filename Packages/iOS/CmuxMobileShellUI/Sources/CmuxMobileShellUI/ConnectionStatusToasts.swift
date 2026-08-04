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
