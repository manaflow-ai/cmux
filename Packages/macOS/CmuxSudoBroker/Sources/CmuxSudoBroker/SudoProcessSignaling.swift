protocol SudoProcessSignaling: Sendable {
    @discardableResult
    func signal(processIdentifier: Int32, signal: Int32) -> Bool

    @discardableResult
    func signal(processGroupIdentifier: Int32, signal: Int32) -> Bool
}
