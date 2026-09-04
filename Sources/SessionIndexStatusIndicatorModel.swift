import SwiftUI

/// Immutable presentation state for the status circle shown beside a Vault
/// session. The private state enum keeps the active flag and accessibility
/// label derived from one source instead of allowing contradictory values.
nonisolated struct SessionIndexStatusIndicatorModel: Equatable, Sendable {
    private enum State: Equatable, Sendable {
        case activeInPane
        case active
        case inactive
    }

    private let state: State

    private init(state: State) {
        self.state = state
    }

    var isActive: Bool {
        switch state {
        case .activeInPane, .active:
            return true
        case .inactive:
            return false
        }
    }

    var label: String {
        switch state {
        case .activeInPane:
            return String(
                localized: "sessionIndex.status.activeInPane",
                defaultValue: "Active in pane"
            )
        case .active:
            return String(
                localized: "sessionIndex.status.activeIndicator",
                defaultValue: "Active"
            )
        case .inactive:
            return String(
                localized: "sessionIndex.status.inactiveIndicator",
                defaultValue: "Inactive"
            )
        }
    }

    var color: Color {
        isActive ? .green : Color.secondary.opacity(0.55)
    }

    /// A process-derived status is authoritative whenever it is available.
    /// This matters for a pane whose agent exited or whose restore command
    /// failed: the pane can remain open at a shell, but the session is no
    /// longer active and must use the inactive treatment. A missing status is
    /// the only case where the in-pane snapshot is used as a fallback.
    nonisolated static func make(
        isInPane: Bool,
        liveStatus: VaultSessionLiveStatus?
    ) -> SessionIndexStatusIndicatorModel {
        if let liveStatus {
            if liveStatus.isActiveForIndicator {
                return SessionIndexStatusIndicatorModel(
                    state: isInPane ? .activeInPane : .active
                )
            }
            return SessionIndexStatusIndicatorModel(state: .inactive)
        }
        if isInPane {
            return SessionIndexStatusIndicatorModel(state: .activeInPane)
        }
        return SessionIndexStatusIndicatorModel(state: .inactive)
    }
}
