/// The action shown by a Computer Use permission row for its current state.
enum ComputerUsePermissionRowAction: Equatable, Sendable {
    enum Destination: Equatable, Sendable {
        case systemSettings
    }

    case allow
    case openSystemSettings
    case done

    /// Both visible permission actions lead directly to the permanent macOS
    /// permission pane. `allow` is the concise first-run label; it must not
    /// raise an intermediate native TCC alert that then asks the user to open
    /// System Settings a second time.
    var destination: Destination? {
        switch self {
        case .allow, .openSystemSettings:
            .systemSettings
        case .done:
            nil
        }
    }

    static func resolve(
        granted: Bool,
        statusIsKnown: Bool,
        systemSettingsOpened: Bool
    ) -> Self {
        guard statusIsKnown else {
            return granted || systemSettingsOpened
                ? .openSystemSettings
                : .allow
        }
        if granted { return .done }
        return systemSettingsOpened ? .openSystemSettings : .allow
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
