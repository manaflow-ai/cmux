import CMUXAuthCore
import Testing
@testable import CmuxAuthRuntime

@Suite struct AuthConfigTests {
    @Test func developmentUsesLocalMagicLinkHandler() {
        let config = AuthConfig(environment: .development)

        #expect(config.magicLinkCallbackURL == "http://localhost:3000/handler/magic-link-callback")
        #expect(config.apiBaseURL == "http://localhost:3000")
    }

    @Test func productionUsesStackWhitelistedCmuxDomain() {
        let config = AuthConfig(environment: .production)

        #expect(config.magicLinkCallbackURL == "https://cmux.com/handler/magic-link-callback")
        #expect(config.apiBaseURL == "https://cmux.com")
    }
}
