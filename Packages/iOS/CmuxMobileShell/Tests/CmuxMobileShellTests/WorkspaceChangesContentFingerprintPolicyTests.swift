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
        expectFailureOtherThanMacUnreachable {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: "stat:10:100:2:300:101",
                observed: "stat:10:100:2:301:101"
            )
        }
    }

    @Test func missingFingerprintAfterEstablishmentDoesNotClaimMacUnreachable() {
        expectFailureOtherThanMacUnreachable {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: "stat:10:100:2:300:101",
                observed: nil
            )
        }
    }

    @Test func missingExpectedFingerprintDoesNotClaimMacUnreachable() {
        expectFailureOtherThanMacUnreachable {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: nil,
                observed: "stat:10:100:2:300:101"
            )
        }
        expectFailureOtherThanMacUnreachable {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: nil,
                observed: nil
            )
        }
    }

    @Test func presentLegacyFingerprintShapeIsRejected() {
        expectFailureOtherThanMacUnreachable {
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: "stat:10:100",
                observed: "stat:10:100"
            )
        }
    }

    private func expectFailureOtherThanMacUnreachable(
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("invalid fingerprint state should fail")
        } catch let error as ChatArtifactError {
            #expect(error != .macUnreachable)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
