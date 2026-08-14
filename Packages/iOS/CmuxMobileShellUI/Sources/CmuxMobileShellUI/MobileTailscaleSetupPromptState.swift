import CmuxMobileShell

/// Session presentation state for the Tailscale setup reminder.
///
/// The shell owns durable setup readiness. This state only latches a requirement
/// already known by the migration route and remembers a dismissal until setup
/// readiness changes away from requiring pairing.
struct MobileTailscaleSetupPromptState: Equatable {
    enum Presentation: Equatable {
        case followsShell
        case required
        case dismissed
    }

    enum Action: Equatable {
        case selectedTailscale(requiresPairing: Bool)
        case shellStatusChanged(MobileTailscaleSetupStatus)
        case dismiss
    }

    private(set) var presentation: Presentation = .followsShell

    var showsBanner: Bool {
        presentation == .required
    }

    mutating func apply(_ action: Action) {
        switch action {
        case let .selectedTailscale(requiresPairing):
            presentation = requiresPairing ? .required : .followsShell

        case let .shellStatusChanged(status):
            switch status {
            case .notSelected, .authorized:
                presentation = .followsShell
            case .loadingAuthorization:
                break
            case .pairingRequired:
                if presentation == .followsShell {
                    presentation = .required
                }
            }

        case .dismiss:
            if presentation == .required {
                presentation = .dismissed
            }
        }
    }
}
