protocol SudoPAMChecking: Sendable {
    func touchIDIsEnabled() -> Bool
}

extension SudoPAMConfiguration: SudoPAMChecking {}
