/// Versioned host evidence for one helper's explicit capture setup in one runtime scope.
struct ComputerUseOnboardingCompletion: Codable, Sendable {
    let version: Int
    let scope: String
    let helperIdentity: String
}
