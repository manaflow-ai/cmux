import CmuxAgentChat
import Testing

@testable import CmuxMobileShell

@Suite struct WorkspaceChangesContentFingerprintPolicyTests {
    @Test func acceptsMatchingStatAndBlobFingerprints() throws {
        let policy = WorkspaceChangesContentFingerprintPolicy()

        try policy.validate(
            expected: "stat:10:100:2:300:101",
            observed: "stat:10:100:2:300:101"
        )
        try policy.validate(
            expected: "blob:abc123:def456",
            observed: "blob:abc123:def456"
        )
    }

    @Test func mismatchFailsWithRetryableArtifactError() {
        #expect(throws: ChatArtifactError.macUnreachable) {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: "stat:10:100:2:300:101",
                observed: "stat:10:100:2:301:101"
            )
        }
    }

    @Test func missingFingerprintAfterEstablishmentFailsWithRetryableError() {
        #expect(throws: ChatArtifactError.macUnreachable) {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: "stat:10:100:2:300:101",
                observed: nil
            )
        }
    }

    @Test func missingExpectedFingerprintFailsWithRetryableError() {
        #expect(throws: ChatArtifactError.macUnreachable) {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: nil,
                observed: "stat:10:100:2:300:101"
            )
        }
        #expect(throws: ChatArtifactError.macUnreachable) {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: nil,
                observed: nil
            )
        }
    }

    @Test func presentLegacyFingerprintShapeIsRejected() {
        #expect(throws: ChatArtifactError.macUnreachable) {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: "stat:10:100",
                observed: "stat:10:100"
            )
        }
    }
}
