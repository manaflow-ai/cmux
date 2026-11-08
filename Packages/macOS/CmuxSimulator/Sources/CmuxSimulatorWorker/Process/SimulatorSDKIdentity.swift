struct SimulatorSDKIdentity: Equatable, Sendable {
    let path: String
    let version: String
    let buildVersion: String
    let compilerVersion: String
    let settingsDigest: String
}
