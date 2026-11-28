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

    @Test func mismatchDoesNotClaimMacUnreachable() {
        #expect(throws: ChatArtifactError.fileChanged) {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: "stat:10:100:2:300:101",
                observed: "stat:10:100:2:301:101"
            )
        }
    }

    @Test func missingFingerprintAfterEstablishmentDoesNotClaimMacUnreachable() {
        #expect(throws: ChatArtifactError.invalidResponse) {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: "stat:10:100:2:300:101",
                observed: nil
            )
        }
    }

    @Test func missingExpectedFingerprintDoesNotClaimMacUnreachable() {
        #expect(throws: ChatArtifactError.invalidResponse) {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: nil,
                observed: "stat:10:100:2:300:101"
            )
        }
        #expect(throws: ChatArtifactError.invalidResponse) {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: nil,
                observed: nil
            )
        }
    }

    @Test func presentLegacyFingerprintShapeIsRejected() {
        #expect(throws: ChatArtifactError.invalidResponse) {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: "stat:10:100",
                observed: "stat:10:100"
            )
        }
    }

}
