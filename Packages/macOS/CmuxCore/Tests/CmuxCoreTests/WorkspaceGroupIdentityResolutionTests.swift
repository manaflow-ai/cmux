import Testing
import CmuxCore

@Suite("Workspace group identity resolution")
struct WorkspaceGroupIdentityResolutionTests {
    @Test("normalizes either accepted alias")
    func normalizesAliases() throws {
        let external = try WorkspaceGroupIdentityResolution(
            externalID: .string("  repo:cmux  ")
        )
        #expect(external.value == "repo:cmux")

        let retry = try WorkspaceGroupIdentityResolution(
            idempotencyKey: .string(" repo:cmux ")
        )
        #expect(retry.value == "repo:cmux")
    }

    @Test("accepts matching aliases after normalization")
    func matchingAliases() throws {
        let resolution = try WorkspaceGroupIdentityResolution(
            externalID: .string("repo:cmux"),
            idempotencyKey: .string(" repo:cmux ")
        )
        #expect(resolution.value == "repo:cmux")
    }

    @Test("omitted and null-equivalent inputs produce no identity")
    func absentInputs() throws {
        let resolution = try WorkspaceGroupIdentityResolution()
        #expect(resolution.value == nil)
    }

    @Test("rejects malformed, blank, and mismatched inputs")
    func validationErrors() {
        #expect(throws: WorkspaceGroupIdentityResolution.ValidationError.nonString(field: .externalID)) {
            try WorkspaceGroupIdentityResolution(externalID: .invalid)
        }
        #expect(throws: WorkspaceGroupIdentityResolution.ValidationError.empty(field: .idempotencyKey)) {
            try WorkspaceGroupIdentityResolution(idempotencyKey: .string(" \n "))
        }
        #expect(throws: WorkspaceGroupIdentityResolution.ValidationError.mismatchedAliases) {
            try WorkspaceGroupIdentityResolution(
                externalID: .string("repo:a"),
                idempotencyKey: .string("repo:b")
            )
        }
    }
}
