internal import Foundation

/// Additional process admission conditions for session restoration.
public struct CmuxAgentRestorableCondition: Codable, Equatable, Hashable, Sendable {
    /// Environment entries that must equal the observed process environment.
    public var environmentEquals: [String: String]

    /// Creates a restoration admission condition.
    public init(environmentEquals: [String: String] = [:]) {
        self.environmentEquals = environmentEquals.reduce(into: [:]) { result, pair in
            result[pair.key.trimmingCharacters(in: .whitespacesAndNewlines)] = pair.value
        }
    }
}
