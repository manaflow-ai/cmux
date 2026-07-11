/// Finds Android SDK tools using injected environment and filesystem state.
public protocol AndroidSDKLocating: Sendable {
    /// Resolves the preferred Android SDK installation.
    func locate() -> AndroidSDKResolution
}
