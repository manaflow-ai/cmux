struct SimulatorCameraAuthorizationRecord: Codable {
    let deviceIdentifier: String
    let bundleIdentifier: String
    let authorization: SimulatorPrivacyAuthorization
}
