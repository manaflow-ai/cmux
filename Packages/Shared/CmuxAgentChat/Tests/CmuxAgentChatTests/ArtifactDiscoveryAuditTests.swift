import Foundation
import Testing
@testable import CmuxAgentChat

@Suite("Artifact discovery audit", .serialized)
struct ArtifactDiscoveryAuditTests {
    @Test("audits real historical transcripts when explicitly enabled")
    func artifactDiscoveryAudit() {
        guard ProcessInfo.processInfo.environment["CMUX_ARTIFACT_AUDIT"] == "1" else {
            return
        }
        ArtifactDiscoveryAudit().run()
    }
}
