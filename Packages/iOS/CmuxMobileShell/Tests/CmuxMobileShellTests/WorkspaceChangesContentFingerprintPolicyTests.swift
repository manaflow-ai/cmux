import CmuxAgentChat
import Testing

@testable import CmuxMobileShell

@Suite struct WorkspaceChangesContentFingerprintPolicyTests {
    @Test func acceptsMatchingAndAllLegacyMissingFingerprints() throws {
        let policy = WorkspaceChangesContentFingerprintPolicy()

        try policy.validate(expected: "stat:10:100", observed: "stat:10:100")
        try policy.validate(expected: nil, observed: "stat:10:200")
        try policy.validate(expected: nil, observed: nil)
    }

    @Test func mismatchFailsWithRetryableArtifactError() {
        #expect(throws: ChatArtifactError.macUnreachable) {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: "stat:10:100",
                observed: "stat:10:200"
            )
        }
    }

    @Test func missingFingerprintAfterEstablishmentFailsWithRetryableError() {
        #expect(throws: ChatArtifactError.macUnreachable) {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: "stat:10:100",
                observed: nil
            )
        }
    }
}
