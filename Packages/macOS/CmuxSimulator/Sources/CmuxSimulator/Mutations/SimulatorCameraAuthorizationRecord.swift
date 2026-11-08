package struct SimulatorCameraAuthorizationRecord: Codable, Equatable {
    package let deviceIdentifier: String
    package let bundleIdentifier: String
    package let authorization: SimulatorPrivacyAuthorization
    package let ownerProcessIdentity: SimulatorProcessIdentity?

    package var isOwnedByRunningProcess: Bool {
        ownerProcessIdentity?.isRunning == true
    }
}
