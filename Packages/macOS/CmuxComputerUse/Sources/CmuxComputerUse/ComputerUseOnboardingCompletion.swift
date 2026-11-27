import Foundation

/// Versioned host evidence for one helper's explicit capture setup in one runtime scope.
public struct ComputerUseOnboardingCompletion: Codable, Sendable {
    /// Completion schema version used for migration and invalidation.
    public let version: Int
    /// Runtime scope to which this completion belongs.
    public let scope: String
    /// Helper signing identity that produced the evidence.
    public let helperIdentity: String

    /// Creates a scoped completion record.
    public init(version: Int, scope: String, helperIdentity: String) {
        self.version = version
        self.scope = scope
        self.helperIdentity = helperIdentity
    }
}
