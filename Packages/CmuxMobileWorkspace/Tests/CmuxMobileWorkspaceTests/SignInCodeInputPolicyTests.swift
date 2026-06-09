import Testing

@testable import CmuxMobileWorkspace

@Suite struct SignInCodeInputPolicyTests {
    @Test func normalizesPastedCodesBeforeVerifying() {
        #expect(SignInCodeInputPolicy.action(for: "12345") == .none)
        #expect(SignInCodeInputPolicy.action(for: "123456") == .verify)
        #expect(SignInCodeInputPolicy.action(for: "123456\n") == .assign("123456"))
        #expect(SignInCodeInputPolicy.action(for: "1234567") == .assign("123456"))
    }
}
