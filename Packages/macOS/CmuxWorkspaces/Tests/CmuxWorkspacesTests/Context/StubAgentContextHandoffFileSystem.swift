import Foundation
@testable import CmuxWorkspaces

/// Injected metadata and read results for handoff-verifier tests.
struct StubAgentContextHandoffFileSystem: AgentContextHandoffFileSystem {
    let snapshotResult: Result<AgentContextHandoffFileSnapshot?, AgentContextHandoffStubError>

    func readSnapshot(
        at _: URL,
        maximumBytes _: Int
    ) async throws -> AgentContextHandoffFileSnapshot? {
        try snapshotResult.get()
    }
}
