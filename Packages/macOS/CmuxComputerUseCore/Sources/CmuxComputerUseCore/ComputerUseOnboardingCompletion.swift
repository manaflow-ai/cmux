import Foundation

/// Versioned host evidence for one helper's explicit capture setup in one runtime scope.
public struct ComputerUseOnboardingCompletion: Codable, Sendable {
    public let version: Int
    public let scope: String
    public let helperIdentity: String

    public init(version: Int, scope: String, helperIdentity: String) {
        self.version = version
        self.scope = scope
        self.helperIdentity = helperIdentity
    }
}
