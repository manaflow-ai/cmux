import Testing
@testable import CmuxMobileDiagnostics

@Suite struct MobileDiagnosticsSecretScrubberTests {
    @Test func redactsTokenCredentialJWTAuthorizationAndEmailValues() {
        let scrubber = MobileDiagnosticsSecretScrubber()
        let input = """
        access_token=access-secret refresh_token=refresh-secret password=hunter2
        Authorization: Bearer bearer-secret-value
        {"access_token":"json-access-secret","password":"json-password-secret"}
        jwt abcdefghijklmnop.qrstuvwxyzABCDEF.ghijklmnopqrstuv
        email user@example.com
        """

        let output = scrubber.scrub(input)

        #expect(!output.contains("access-secret"))
        #expect(!output.contains("refresh-secret"))
        #expect(!output.contains("hunter2"))
        #expect(!output.contains("json-access-secret"))
        #expect(!output.contains("json-password-secret"))
        #expect(!output.contains("bearer-secret-value"))
        #expect(!output.contains("abcdefghijklmnop"))
        #expect(!output.contains("user@example.com"))
        #expect(output.contains("access_token=<redacted>"))
        #expect(output.contains(#""access_token":"<redacted>""#))
        #expect(output.contains("Authorization=<redacted>"))
    }
}
