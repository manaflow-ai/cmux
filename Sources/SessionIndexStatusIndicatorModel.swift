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

    /// A known-running pane is authoritative while the process index catches
    /// up after a resume. The parent supplies this flag only for panes whose
    /// shell reports a foreground command, so a pane that has returned to its
    /// shell after an exit cannot remain green. Indexed rows use the
    /// process-derived status when no active pane is known.
    nonisolated static func make(
        isInPane: Bool,
        liveStatus: VaultSessionLiveStatus?
    ) -> SessionIndexStatusIndicatorModel {
        if isInPane {
            return SessionIndexStatusIndicatorModel(state: .activeInPane)
        }
        if liveStatus?.isActiveForIndicator == true {
            return SessionIndexStatusIndicatorModel(state: .active)
        }
        return SessionIndexStatusIndicatorModel(state: .inactive)
    }
}
