import Testing
@testable import CmuxiOSConfig

@Suite struct EnvironmentStringOverrideTests {
    @Test func prefersEnvironmentVariableOverLocalConfig() {
        let value = Environment.stringOverride(
            devKey: "API_BASE_URL_DEV",
            prodKey: "API_BASE_URL_PROD",
            environment: .development,
            environmentVariables: ["API_BASE_URL_DEV": "https://env.example.com"],
            localConfig: ["API_BASE_URL_DEV": "https://plist.example.com"]
        )
        #expect(value == "https://env.example.com")
    }

    @Test func fallsBackToLocalConfigWhenNoEnvVar() {
        let value = Environment.stringOverride(
            devKey: "API_BASE_URL_DEV",
            prodKey: "API_BASE_URL_PROD",
            environment: .development,
            environmentVariables: [:],
            localConfig: ["API_BASE_URL_DEV": "https://plist.example.com"]
        )
        #expect(value == "https://plist.example.com")
    }

    @Test func selectsProdKeyInProduction() {
        let value = Environment.stringOverride(
            devKey: "API_BASE_URL_DEV",
            prodKey: "API_BASE_URL_PROD",
            environment: .production,
            environmentVariables: ["API_BASE_URL_DEV": "dev", "API_BASE_URL_PROD": "prod"],
            localConfig: nil
        )
        #expect(value == "prod")
    }

    @Test func usesLegacyKeyAfterEnvironmentKey() {
        let value = Environment.stringOverride(
            devKey: "API_BASE_URL_DEV",
            prodKey: "API_BASE_URL_PROD",
            legacyKey: "API_BASE_URL",
            environment: .development,
            environmentVariables: ["API_BASE_URL": "legacy"],
            localConfig: nil
        )
        #expect(value == "legacy")
    }

    @Test func trimsWhitespaceAndIgnoresEmpty() {
        let value = Environment.stringOverride(
            devKey: "K_DEV",
            prodKey: "K_PROD",
            environment: .development,
            environmentVariables: ["K_DEV": "   "],
            localConfig: ["K_DEV": "  trimmed  "]
        )
        #expect(value == "trimmed")
    }

    @Test func returnsNilWhenNothingMatches() {
        let value = Environment.stringOverride(
            devKey: "K_DEV",
            prodKey: "K_PROD",
            environment: .development,
            environmentVariables: [:],
            localConfig: nil
        )
        #expect(value == nil)
    }
}

@Suite struct EnvironmentResolvedAPIBaseURLTests {
    @Test func acceptsHTTPSCandidate() {
        let resolved = Environment.resolvedAPIBaseURL(
            candidate: "https://api.example.com",
            environment: .production,
            allowInsecureLocalOverride: false
        )
        #expect(resolved == "https://api.example.com")
    }

    @Test func rejectsInsecureCandidateWhenOverrideDisallowed() {
        let resolved = Environment.resolvedAPIBaseURL(
            candidate: "http://localhost:3000",
            environment: .production,
            allowInsecureLocalOverride: false
        )
        #expect(resolved == "https://api.cmux.sh")
    }

    @Test func acceptsInsecureCandidateWhenOverrideAllowed() {
        let resolved = Environment.resolvedAPIBaseURL(
            candidate: "http://localhost:3000",
            environment: .development,
            allowInsecureLocalOverride: true
        )
        #expect(resolved == "http://localhost:3000")
    }

    @Test func fallsBackOnUnparseableCandidate() {
        let resolved = Environment.resolvedAPIBaseURL(
            candidate: "",
            environment: .development,
            allowInsecureLocalOverride: true
        )
        #expect(resolved == "https://api.cmux.sh")
    }
}

@Suite struct EnvironmentNameTests {
    @Test func developmentName() {
        #expect(Environment.development.name == "Development")
    }

    @Test func productionName() {
        #expect(Environment.production.name == "Production")
    }
}
