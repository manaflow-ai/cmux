import CMUXAgentLaunch
import Testing

@Suite("Managed agent stall classification")
struct AgentStallClassifierTests {
    private let classifier = AgentStallClassifier()

    @Test("classifies the full OpenAI Trusted Access refusal as human-required")
    func trustedAccessRefusal() throws {
        let output = """
        ⓘ This content can't be shown

        We take extra caution with cybersecurity requests. If you're a security
        professional, you may be able to apply for Trusted Access.

        Trusted Access: https://openai.com/form/enterprise-trusted-access-for-cyber/
        Learn more: https://help.openai.com/en/articles/20001326
        """

        let result = try #require(classifier.classify(provider: "codex", output: output))

        #expect(result.cause == .safeguardRefusal)
        #expect(result.disposition == .humanRequired)
        #expect(result.patternIdentifier == "openai.trusted-access.cybersecurity-refusal")
        #expect(result.retryActionID == nil)
    }

    @Test("classifies the current Codex Trusted Access warning icon")
    func trustedAccessWarningIcon() throws {
        let output = """
        ⚠ This content can't be shown
        We take extra caution with cybersecurity requests. If you’re a security
        professional, you may be able to apply for Trusted Access.
        """

        let result = try #require(classifier.classify(provider: "codex", output: output))
        #expect(result.cause == .safeguardRefusal)
        #expect(result.patternIdentifier == "openai.trusted-access.cybersecurity-refusal")
    }

    @Test("classifies Trusted Access evidence when terminal wrapping splits a phrase")
    func wrappedTrustedAccessRefusal() throws {
        let output = """
        This content can't be shown
        We take extra caution with cyber
        security requests. Apply for Trusted Access.
        """

        let result = try #require(classifier.classify(provider: "codex", output: output))
        #expect(result.cause == .safeguardRefusal)
    }

    @Test("an incomplete Trusted Access refusal fails closed")
    func incompleteTrustedAccessRefusal() {
        let output = """
        This content can't be shown.
        Learn more about Trusted Access in the provider documentation.
        """

        #expect(classifier.classify(provider: "codex", output: output) == nil)
    }

    @Test("classifies a captured rate-limit banner as retryable")
    func rateLimitBanner() throws {
        let result = try #require(classifier.classify(
            provider: "codex",
            output: "API error: 429 Too Many Requests — rate limit reached."
        ))

        #expect(result.cause == .rateLimit)
        #expect(result.disposition == .retryable)
        #expect(result.retryActionID == "replayLastPrompt")
    }

    @Test("classifies Anthropic usage-credit exhaustion as human-required")
    func anthropicCredits() throws {
        let result = try #require(classifier.classify(
            provider: "claude_code",
            output: "This request requires usage credits. Add credits to continue."
        ))

        #expect(result.provider == "claude")
        #expect(result.cause == .quotaExhausted)
        #expect(result.disposition == .humanRequired)
    }

    @Test("classifies captured Claude Code quota banners as human-required")
    func claudeQuotaBanners() throws {
        for output in [
            "Credit balance is too low",
            "Fable 5 requires usage credits.",
            "Usage limit reached",
            "You're out of extra usage",
        ] {
            let result = try #require(classifier.classify(
                provider: "claude",
                output: output
            ))
            #expect(result.cause == .quotaExhausted)
            #expect(result.disposition == .humanRequired)
        }
    }

    @Test("classifies captured Claude Code authentication banners as human-required")
    func claudeAuthenticationBanners() throws {
        for output in [
            "Not logged in · Please run /login",
            "Your session has expired. Please run /login to sign in again.",
            "Invalid API key · Fix external API key",
            "Invalid auth token · Fix external auth token",
        ] {
            let result = try #require(classifier.classify(
                provider: "claude",
                output: output
            ))
            #expect(result.cause == .authenticationExpired)
            #expect(result.disposition == .humanRequired)
        }
    }

    @Test("classifies captured Claude Code transient API banners as retryable")
    func claudeTransientBanners() throws {
        for output in [
            "API overloaded",
            "Repeated 529 Overloaded errors",
            "Unable to connect to API (ECONNREFUSED)",
            "Couldn't connect through your proxy (connection reset)",
            "API error (status 503): Service Unavailable",
        ] {
            let result = try #require(classifier.classify(
                provider: "claude",
                output: output
            ))
            #expect(result.disposition == .retryable)
            #expect(result.retryActionID == "replayLastPrompt")
        }
    }

    @Test("classifies the Codex usage-limit and credit-purchase banner as human-required")
    func codexUsageLimitBanner() throws {
        let result = try #require(classifier.classify(
            provider: "codex",
            output: "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 4:05 AM."
        ))

        #expect(result.cause == .quotaExhausted)
        #expect(result.disposition == .humanRequired)
        #expect(result.patternIdentifier == "codex.usage-limit-banner")
    }

    @Test("classifies Codex overload banners from transcript fixtures")
    func codexOverloadBanners() throws {
        let ambiguous = try #require(classifier.classify(
            provider: "codex",
            output: "Try again later.",
            hasStructuredEvidence: true
        ))
        #expect(ambiguous.cause == .overload)
        #expect(ambiguous.disposition == .retryable)
        #expect(ambiguous.retryActionID == "replayLastPrompt")

        let modelCapacity = try #require(classifier.classify(
            provider: "codex",
            output: "Selected model is at capacity. Please try a different model."
        ))
        #expect(modelCapacity.cause == .overload)
        #expect(modelCapacity.disposition == .retryable)
        #expect(modelCapacity.retryActionID == "replayLastPrompt")
    }

    @Test("ambiguous overload prose requires structured hook evidence")
    func ambiguousOverloadFailsClosedWithoutHookEvidence() {
        #expect(classifier.classify(
            provider: "codex",
            output: "Try again later."
        ) == nil)
    }

    @Test("classifies a structured Codex quota signal without retrying it")
    func codexStructuredQuotaSignal() throws {
        let result = try #require(classifier.classify(
            provider: "codex",
            output: "event_msg error codex_error_info=usage_limit_exceeded",
            hasStructuredEvidence: true
        ))

        #expect(result.cause == .quotaExhausted)
        #expect(result.disposition == .humanRequired)
    }

    @Test("classifies structured Codex safeguard and transport signals")
    func codexStructuredSignals() throws {
        let safeguard = try #require(classifier.classify(
            provider: "codex",
            output: "event_msg error codex_error_info=cyber_policy",
            hasStructuredEvidence: true
        ))
        #expect(safeguard.cause == .safeguardRefusal)
        #expect(safeguard.disposition == .humanRequired)

        let transport = try #require(classifier.classify(
            provider: "codex",
            output: "event_msg error codex_error_info=http_connection_failed",
            hasStructuredEvidence: true
        ))
        #expect(transport.cause == .transientTransport)
        #expect(transport.disposition == .retryable)
    }

    @Test("structured Codex vocabulary in ordinary output fails closed")
    func codexStructuredVocabularyRequiresHookEvidence() {
        for output in [
            "event_msg error codex_error_info=cyber_policy",
            "event_msg error codex_error_info=usage_limit_exceeded",
            "event_msg error codex_error_info=http_connection_failed",
            "Handled server_overloaded and told the caller to try again later.",
        ] {
            #expect(classifier.classify(provider: "codex", output: output) == nil)
        }
    }

    @Test("classifies standalone 429 and 5xx provider status banners")
    func standaloneProviderStatusBanners() throws {
        let rateLimit = try #require(classifier.classify(
            provider: "codex",
            output: "429 Too Many Requests"
        ))
        #expect(rateLimit.cause == .rateLimit)

        let serverError = try #require(classifier.classify(
            provider: "claude",
            output: "503 Service Unavailable"
        ))
        #expect(serverError.cause == .transientTransport)
    }

    @Test("classifies parenthesized provider status errors")
    func parenthesizedProviderStatusErrors() throws {
        let rateLimit = try #require(classifier.classify(
            provider: "codex",
            output: "API error (status 429): Too Many Requests"
        ))
        #expect(rateLimit.cause == .rateLimit)

        let serverError = try #require(classifier.classify(
            provider: "claude",
            output: "API error (status 503): Service Unavailable"
        ))
        #expect(serverError.cause == .transientTransport)
    }

    @Test("classifies expanded usage-limit banners without matching prose")
    func expandedUsageLimitBanners() throws {
        for output in [
            "You have reached your usage limit. Try again later.",
            "You've exceeded your usage limit.",
            "Your usage limit has been exceeded.",
            "Usage limit reached",
        ] {
            let result = try #require(classifier.classify(
                provider: "codex",
                output: output
            ))
            #expect(result.cause == .quotaExhausted)
            #expect(result.disposition == .humanRequired)
        }
        #expect(classifier.classify(
            provider: "codex",
            output: "I explained how your usage limit has been exceeded in the docs."
        ) == nil)
    }

    @Test("classifies explicit overload wording as retryable")
    func explicitOverloadWording() throws {
        let result = try #require(classifier.classify(
            provider: "codex",
            output: "The API is currently overloaded. Please try again later."
        ))
        #expect(result.cause == .overload)
        #expect(result.disposition == .retryable)
    }

    @Test("classifies an expired provider token as human-required")
    func expiredTokenBanner() throws {
        let result = try #require(classifier.classify(
            provider: "codex",
            output: "Your access token has expired. Please log in again."
        ))

        #expect(result.cause == .authenticationExpired)
        #expect(result.disposition == .humanRequired)
        #expect(result.retryActionID == nil)
    }

    @Test(
        "normalizes managed-provider aliases",
        arguments: [
            ("claude", "claude"),
            ("claude_code", "claude"),
            ("anthropic", "claude"),
            ("codex", "codex"),
            ("codex-cli", "codex"),
            ("openai", "codex"),
        ]
    )
    func providerAliases(provider: String, expectedProvider: String) throws {
        let output = provider == "claude" || provider == "claude_code" || provider == "anthropic"
            ? "API error: connection reset by peer"
            : "API error: connection refused"

        let result = try #require(classifier.classify(provider: provider, output: output))

        #expect(result.provider == expectedProvider)
        #expect(result.cause == .transientTransport)
    }

    @Test("normalizes provider aliases declared by custom rules")
    func customPatternProviderAliases() throws {
        let customClassifier = AgentStallClassifier(patterns: [
            AgentStallPattern(
                identifier: "custom.anthropic.transport",
                providers: ["claude_code", "anthropic"],
                cause: .transientTransport,
                requiredFragments: ["custom transport failure"],
                retryActionID: "replayLastPrompt",
                suggestedActionID: "retryAutomatically"
            ),
        ])

        let result = try #require(customClassifier.classify(
            provider: "claude-code",
            output: "Custom transport failure"
        ))

        #expect(result.provider == "claude")
        #expect(result.patternIdentifier == "custom.anthropic.transport")
    }

    @Test("ANSI decoration does not hide a transport error")
    func ansiTransportError() throws {
        let result = try #require(classifier.classify(
            provider: "openai",
            output: "\u{001B}[31mHTTP 503\u{001B}[0m service unavailable"
        ))

        #expect(result.cause == .overload || result.cause == .transientTransport)
        #expect(result.disposition == .retryable)
    }

    @Test("an API 599 response classifies while a bare 503 does not")
    func serverStatusContext() throws {
        let result = try #require(classifier.classify(
            provider: "codex",
            output: "API error: 599 upstream transport failure"
        ))

        #expect(result.cause == .transientTransport)
        #expect(classifier.classify(provider: "codex", output: "Build 503 completed") == nil)
    }

    @Test("quota vocabulary in successful prose fails closed")
    func quotaVocabularyInSuccessfulProse() {
        let output = """
        Done. I documented how usage credits and the usage limit work without
        changing the customer's current quota.
        """

        #expect(classifier.classify(provider: "claude", output: output) == nil)
    }

    @Test("quota error vocabulary in successful prose does not become a banner")
    func quotaErrorVocabularyInSuccessfulProse() {
        let output = "Completed. I documented credit limit exceeded handling for the client."
        #expect(classifier.classify(provider: "claude", output: output) == nil)
    }

    @Test("transport vocabulary in successful prose fails closed")
    func transportVocabularyInSuccessfulProse() {
        let output = """
        Done. I fixed the connection reset handling and documented the recovery
        path for future maintainers.
        """

        #expect(classifier.classify(provider: "codex", output: output) == nil)
    }

    @Test("error vocabulary in successful prose does not become a banner")
    func errorVocabularyInSuccessfulProse() {
        let output = "Completed. I documented API error handling for connection reset behavior."
        #expect(classifier.classify(provider: "codex", output: output) == nil)
    }

    @Test("a custom rule without positive evidence fails closed")
    func emptyCustomRule() {
        let customClassifier = AgentStallClassifier(patterns: [
            AgentStallPattern(
                identifier: "custom.empty",
                providers: ["codex"],
                cause: .transientTransport,
                suggestedActionID: "retryAutomatically"
            ),
        ])

        #expect(customClassifier.classify(provider: "codex", output: "Done.") == nil)
    }

    @Test("unknown output, provider, and normal completion fail closed")
    func failClosed() {
        #expect(classifier.classify(provider: "codex", output: "Done.\n> ") == nil)
        #expect(classifier.classify(provider: "unknown-agent", output: "API error: 429 rate limit") == nil)
        #expect(classifier.classify(provider: "codex", output: "The task completed successfully") == nil)
    }

    @Test("bare status codes do not classify without error context")
    func bareStatusCodesFailClosed() {
        #expect(classifier.classify(provider: "codex", output: "The value 429 was mentioned in a log") == nil)
        #expect(classifier.classify(provider: "codex", output: "A previous 401 example") == nil)
        #expect(classifier.classify(provider: "codex", output: "Build 503 completed") == nil)
        #expect(classifier.classify(provider: "codex", output: "The API response 503 example now passes") == nil)
        #expect(classifier.classify(provider: "codex", output: "HTTP 401 examples are documented") == nil)
        #expect(classifier.classify(provider: "codex", output: "HTTP 503 examples are documented") == nil)
        #expect(classifier.classify(provider: "codex", output: "API response: 503 examples now pass") == nil)
        #expect(classifier.classify(provider: "codex", output: "API status: 429 examples now pass") == nil)
    }

    @Test("non-stalling Claude Code feature notices fail closed")
    func claudeFeatureNoticesFailClosed() {
        #expect(classifier.classify(
            provider: "claude",
            output: "Fast mode requires usage credits and has been disabled."
        ) == nil)
    }
}
