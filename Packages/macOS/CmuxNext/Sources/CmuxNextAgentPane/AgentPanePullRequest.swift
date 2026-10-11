import Foundation

/// The pull request of a chat folder's branch, as the chat header's chip shows it (cx-tcwj).
public nonisolated struct AgentPanePullRequest: Equatable, Sendable {
    public struct Checks: Equatable, Sendable {
        public var state: String
        public var passed: Int
        public var total: Int

        public init(state: String, passed: Int, total: Int) {
            self.state = state
            self.passed = passed
            self.total = total
        }
    }

    public var url: String
    public var number: Int
    public var state: String
    public var checks: Checks

    public init(url: String, number: Int, state: String, checks: Checks) {
        self.url = url
        self.number = number
        self.state = state
        self.checks = checks
    }

    public init?(ghView: Data) {
        return nil
    }
}
