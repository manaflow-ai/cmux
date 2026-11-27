import CmuxMobileShell

/// Session state for the Tailscale setup requirement.
///
/// The shell owns durable setup readiness. This state only latches a requirement
/// already known by the migration route while authorization is still loading.
struct MobileTailscaleSetupPromptState: Equatable {
    enum Presentation: Equatable {
        case followsShell
        case required
    }

    enum Action: Equatable {
        case selectedTailscale(requiresPairing: Bool)
        case shellStatusChanged(MobileTailscaleSetupStatus)
    }

    private(set) var presentation: Presentation = .followsShell

    var requiresPairing: Bool {
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

        }
    }
}
