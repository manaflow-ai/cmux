import CMUXAuthCore
import Testing
@testable import CmuxAuthRuntime

@Suite struct AuthConfigTests {
    @Test func productionUsesStackWhitelistedCmuxDomain() {
        let config = AuthConfig(environment: .production)

        #expect(config.magicLinkCallbackURL == "https://cmux.com/auth/callback")
        #expect(config.apiBaseURL == "https://cmux.com")
    }

    @Test func webOriginOverrideMovesCallbackAndAPIBase() {
        let config = AuthConfig(
            environment: .development,
            overrides: ["WebOriginURL": "https://cmux-staging.vercel.app/"]
        )

        #expect(config.magicLinkCallbackURL == "https://cmux-staging.vercel.app/auth/callback")
        #expect(config.apiBaseURL == "https://cmux-staging.vercel.app")
    }

    @Test func explicitApiBaseURLStillBeatsWebOrigin() {
        let config = AuthConfig(
            environment: .development,
            overrides: [
                "WebOriginURL": "https://cmux-staging.vercel.app",
                "ApiBaseURL": "http://localhost:3900",
            ]
        )

        #expect(config.magicLinkCallbackURL == "https://cmux-staging.vercel.app/auth/callback")
        #expect(config.apiBaseURL == "http://localhost:3900")
    }

    @Test func emptyWebOriginOverrideIsIgnored() {
        let config = AuthConfig(environment: .production, overrides: ["WebOriginURL": ""])

        #expect(config.magicLinkCallbackURL == "https://cmux.com/auth/callback")
        #expect(config.apiBaseURL == "https://cmux.com")
    }
}
