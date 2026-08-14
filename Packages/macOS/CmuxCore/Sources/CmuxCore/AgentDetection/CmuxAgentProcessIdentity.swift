internal import Foundation

/// OR-ed process matcher alternatives evaluated in declaration order.
public struct CmuxAgentProcessIdentity: Codable, Equatable, Hashable, Sendable {
    /// Process matcher alternatives.
    public var matchers: [CmuxAgentProcessMatcher]

    /// Creates a process identity expression.
    ///
    /// - Parameter matchers: OR-ed matcher alternatives in evaluation order.
    public init(matchers: [CmuxAgentProcessMatcher] = []) {
        self.matchers = matchers
    }
}
