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

    /// The Vault circle represents a session that is active and focusable in
    /// this cmux window. The parent supplies this flag only for panes whose
    /// shell reports a foreground command, so a pane that has returned to its
    /// shell cannot remain green. A process running in another terminal (or
    /// one that cannot be mapped to a pane) remains gray here.
    nonisolated static func make(
        isInPane: Bool,
        liveStatus: VaultSessionLiveStatus?
    ) -> SessionIndexStatusIndicatorModel {
        _ = liveStatus
        return SessionIndexStatusIndicatorModel(
            state: isInPane ? .activeInPane : .inactive
        )
    }
}
