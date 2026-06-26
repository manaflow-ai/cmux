import CMUXAuthCore
import Testing
@testable import CmuxAuthRuntime

@Suite struct AuthConfigTests {
    @Test func productionUsesStackWhitelistedCmuxDomain() {
        let config = AuthConfig(environment: .production)

        #expect(config.magicLinkCallbackURL == "https://cmux.com/handler/magic-link-callback")
        #expect(config.apiBaseURL == "https://cmux.com")
    }
}
