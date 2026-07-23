/// The action shown by a Computer Use permission row for its current state.
enum ComputerUsePermissionRowAction: Equatable, Sendable {
    case allow
    case checkStatus
    case completeInSystemSettings
    case done

    static func resolve(
        granted: Bool,
        statusIsKnown: Bool,
        nativeRequestAttempted: Bool
    ) -> Self {
        guard statusIsKnown else { return .checkStatus }
        if granted { return .done }
        return nativeRequestAttempted ? .completeInSystemSettings : .allow
    }
}
