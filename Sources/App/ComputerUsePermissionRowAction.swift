/// The action shown by a Computer Use permission row for its current state.
enum ComputerUsePermissionRowAction: Equatable, Sendable {
    enum Destination: Equatable, Sendable {
        case systemSettings
    }

    case allow
    case done

    /// Allow always leads directly to the permanent macOS permission pane. It
    /// stays Allow until the helper reports the grant, including after System
    /// Settings has already opened once.
    var destination: Destination? {
        switch self {
        case .allow:
            .systemSettings
        case .done:
            nil
        }
    }

    static func resolve(
        granted: Bool,
        statusIsKnown: Bool,
        systemSettingsOpened _: Bool
    ) -> Self {
        statusIsKnown && granted ? .done : .allow
    }

    /// Helper installation happens independently when onboarding appears.
    /// Keep Allow actionable while that background preparation is still
    /// resolving the standalone helper; only an active System Settings launch
    /// should suppress duplicate clicks.
    static func isButtonEnabled(
        helperIsReady _: Bool,
        permissionSetupInFlight: Bool
    ) -> Bool {
        !permissionSetupInFlight
    }
}
