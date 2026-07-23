/// The action shown by a Computer Use permission row for its current state.
enum ComputerUsePermissionRowAction: Equatable, Sendable {
    case allow
    case checkStatus
    case done

    static func resolve(
        granted: Bool,
        statusIsKnown: Bool,
        nativeRequestAttempted _: Bool
    ) -> Self {
        guard statusIsKnown else { return granted ? .checkStatus : .allow }
        if granted { return .done }
        return .allow
    }
}
