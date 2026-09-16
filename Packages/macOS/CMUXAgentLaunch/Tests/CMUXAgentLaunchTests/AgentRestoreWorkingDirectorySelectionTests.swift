import Foundation
import Testing
@testable import CMUXAgentLaunch

struct AgentRestoreWorkingDirectorySelectionTests {
    @Test("Exact and unavailable selections survive persistence")
    func persistsRestrictiveSelections() throws {
        for selection in [
            AgentRestoreWorkingDirectorySelection.exact("/home/remote/project"),
            .exact(nil),
            .unavailable,
        ] {
            let data = try JSONEncoder().encode(selection)
            let decoded = try JSONDecoder().decode(
                AgentRestoreWorkingDirectorySelection.self,
                from: data
            )
            #expect(decoded == selection)
        }
    }

    @Test("Stored selections cannot be weakened by later callers")
    func retainsStricterSelection() {
        let storedDirectory = "/home/remote/project"
        let capturedDirectory = "/Users/alice/captured"

        #expect(
            AgentRestoreWorkingDirectorySelection.exact(storedDirectory).restricted(
                by: .recordedFallback(preferred: capturedDirectory)
            ) == .exact(storedDirectory)
        )
        #expect(
            AgentRestoreWorkingDirectorySelection.unavailable.restricted(
                by: .exact(capturedDirectory)
            ) == .unavailable
        )
        #expect(
            AgentRestoreWorkingDirectorySelection.exact(storedDirectory).restricted(
                by: .exact(nil)
            ) == .exact(nil)
        )
    }

    @Test("A nil fallback proposal retains the stored preferred directory")
    func retainsStoredFallbackWhenProposalHasNoPreferredDirectory() {
        let stored = AgentRestoreWorkingDirectorySelection.recordedFallback(
            preferred: "/home/remote/project"
        )
        let restricted = stored.restricted(
            by: .recordedFallback(preferred: nil)
        )

        #expect(restricted == stored)
        #expect(
            restricted.resolved(
                snapshotWorkingDirectory: "/Users/local/snapshot",
                launchWorkingDirectory: "/Users/local/launch"
            ) == "/home/remote/project"
        )
    }

    @Test("A blank fallback proposal is treated as having no preferred directory")
    func retainsStoredFallbackWhenProposalIsBlank() {
        let stored = AgentRestoreWorkingDirectorySelection.recordedFallback(
            preferred: "/home/remote/project"
        )
        let restricted = stored.restricted(
            by: .recordedFallback(preferred: "   ")
        )

        #expect(restricted == stored)
        #expect(
            restricted.resolved(
                snapshotWorkingDirectory: "/Users/local/snapshot",
                launchWorkingDirectory: nil
            ) == "/home/remote/project"
        )
    }

    @Test("Exact nil never falls back to captured cwd values")
    func exactNilDoesNotFallBack() {
        #expect(
            AgentRestoreWorkingDirectorySelection.exact(nil).resolved(
                snapshotWorkingDirectory: "/Users/alice/snapshot",
                launchWorkingDirectory: "/Users/alice/launch"
            ) == nil
        )
    }

    @Test("A newer authoritative exact selection refreshes an older exact value")
    func refreshesAuthoritativeExactSelection() {
        let initial = AgentRestoreWorkingDirectorySelection.exact("/repo-a")
        #expect(
            initial.refreshedByAuthoritativeRemoteSelection(.exact("/repo-b")) ==
                .exact("/repo-b")
        )
        #expect(
            AgentRestoreWorkingDirectorySelection.exact(nil)
                .refreshedByAuthoritativeRemoteSelection(.exact("/repo-b")) ==
                .exact("/repo-b")
        )
        #expect(
            AgentRestoreWorkingDirectorySelection.unavailable
                .refreshedByAuthoritativeRemoteSelection(.exact("/repo-b")) ==
                .unavailable
        )
    }
}
