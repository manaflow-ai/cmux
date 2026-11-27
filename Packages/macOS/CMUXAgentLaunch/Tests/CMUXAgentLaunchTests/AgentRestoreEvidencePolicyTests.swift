import Testing
@testable import CMUXAgentLaunch

@Suite
struct AgentRestoreEvidencePolicyTests {
    @Test("A free provider lock resolves failed global scans", arguments: [true, false])
    func providerEvidenceResolvesScanFailure(indexComplete: Bool) {
        #expect(AgentRestoreEvidencePolicy().decision(
            hasLiveOwner: false, indexComplete: indexComplete, writerLock: .available
        ) == .claimLaunch)
    }

    @Test("A live process generation is never duplicated", arguments: [true, false])
    func liveOwnerRetainsOwnership(indexComplete: Bool) {
        #expect(AgentRestoreEvidencePolicy().decision(
            hasLiveOwner: true, indexComplete: indexComplete, writerLock: .available
        ) == .observeOwner)
    }

    @Test("Inconclusive provider evidence remains recoverable", arguments: [
        CodexWriterLockInspection.State.active, .changing, .unavailable
    ])
    func busyOrInaccessibleProviderRetainsIntent(state: CodexWriterLockInspection.State) {
        #expect(AgentRestoreEvidencePolicy().decision(
            hasLiveOwner: false, indexComplete: true, writerLock: state
        ) == .refreshEvidence)
    }

    @Test("Providers without a lock require complete process evidence")
    func otherProvidersNeverFailOpen() {
        #expect(AgentRestoreEvidencePolicy().decision(
            hasLiveOwner: false, indexComplete: false, writerLock: nil
        ) == .refreshEvidence)
        #expect(AgentRestoreEvidencePolicy().decision(
            hasLiveOwner: false, indexComplete: true, writerLock: nil
        ) == .claimLaunch)
    }
}
