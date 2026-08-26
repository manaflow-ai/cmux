import Foundation
@testable import CmuxWorkspaces

/// Injected metadata and read results for handoff-verifier tests.
struct StubAgentContextHandoffFileSystem: AgentContextHandoffFileSystem {
    let metadataResult: Result<AgentContextHandoffFileMetadata?, AgentContextHandoffStubError>
    let dataResult: Result<Data, AgentContextHandoffStubError>

    func metadata(for _: URL) async throws -> AgentContextHandoffFileMetadata? {
        try metadataResult.get()
    }

    func readData(at _: URL, maximumBytes _: Int) async throws -> Data {
        try dataResult.get()
    }
}
