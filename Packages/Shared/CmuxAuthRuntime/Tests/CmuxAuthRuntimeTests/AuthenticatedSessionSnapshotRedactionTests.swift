import Testing
@testable import CmuxAuthRuntime

@Suite
struct AuthenticatedSessionSnapshotRedactionTests {
    @Test
    func descriptionsRedactAccountAndCredentials() {
        let snapshot = AuthenticatedSessionSnapshot(
            generation: 42,
            accountID: "account-secret",
            accessToken: "access-secret",
            refreshToken: "refresh-secret"
        )

        for rendered in [String(describing: snapshot), String(reflecting: snapshot)] {
            #expect(rendered.contains("generation: 42"))
            #expect(rendered.contains("<redacted>"))
            #expect(!rendered.contains("account-secret"))
            #expect(!rendered.contains("access-secret"))
            #expect(!rendered.contains("refresh-secret"))
        }
    }
}
