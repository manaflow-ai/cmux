/// The action shown by a Computer Use permission row for its current state.
enum ComputerUsePermissionRowAction: Equatable, Sendable {
    case allow
    case openSystemSettings
    case done

    static func resolve(
        granted: Bool,
        statusIsKnown: Bool,
        nativeRequestAttempted: Bool
    ) -> Self {
        guard statusIsKnown else {
            return granted || nativeRequestAttempted
                ? .openSystemSettings
                : .allow
        }
        if granted { return .done }
        return nativeRequestAttempted ? .openSystemSettings : .allow
    }

    /// Helper installation happens independently when onboarding appears.
    /// Keep Allow actionable while that background preparation is still
    /// resolving the standalone helper; only an actively dispatched
    /// permission request should suppress duplicate clicks.
    static func isButtonEnabled(
        helperIsReady _: Bool,
        permissionSetupInFlight: Bool
    ) -> Bool {
        !permissionSetupInFlight
    }
}
