/// The action shown by a Computer Use permission row for its current state.
enum ComputerUsePermissionRowAction: Equatable, Sendable {
    case allow
    case completeInSystemSettings
    case done

    static func resolve(granted: Bool, nativeRequestAttempted: Bool) -> Self {
        if granted { return .done }
        return nativeRequestAttempted ? .completeInSystemSettings : .allow
    }
}
