import Foundation

/// Deterministic filesystem failure used by handoff-verifier tests.
enum AgentContextHandoffStubError: Error, Sendable {
    case readFailed
}
