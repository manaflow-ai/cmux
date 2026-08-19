import Foundation

public extension AgentStallClassifier {
    /// Built-in provider rules ordered from specific human-required states to broader transient failures.
    static let builtInPatterns: [AgentStallPattern] = [
        AgentStallPattern(
            identifier: "openai.trusted-access.cybersecurity-refusal",
            providers: ["codex"],
            cause: .safeguardRefusal,
            requiredFragments: [
                "this content can't be shown",
                "we take extra caution with cybersecurity requests",
                "trusted access",
            ],
            regularExpressions: ["(?m)^\\s*.{0,4}this content can't be shown[.!]?\\s*$"],
            suggestedActionID: "trustedAccess"
        ),
        AgentStallPattern(
            identifier: "codex.cyber-policy-signal",
            providers: ["codex"],
            cause: .safeguardRefusal,
            requiredFragments: ["cyber_policy"],
            anyFragments: ["codex_error_info", "event_msg error", "cyber_policy"],
            requiresStructuredEvidence: true,
            suggestedActionID: "trustedAccess"
        ),
        AgentStallPattern(
            identifier: "anthropic.usage-credits",
            providers: ["claude"],
            cause: .quotaExhausted,
            anyFragments: [
                "requires usage credits",
                "not enough usage credits",
                "insufficient usage credits",
            ],
            regularExpressions: [
                "(?m)^\\s*(?:this request |claude code )?(?:requires usage credits|not enough usage credits|insufficient usage credits)(?:[.!].*)?$",
            ],
            suggestedActionID: "restoreCredits"
        ),
        AgentStallPattern(
            identifier: "anthropic.quota-banner",
            providers: ["claude"],
            cause: .quotaExhausted,
            anyFragments: [
                "credit balance is too low",
                "fable 5 requires usage credits",
                "usage limit reached",
                "you're out of extra usage",
                "you’re out of extra usage",
            ],
            regularExpressions: [
                "(?m)^\\s*(?:credit balance is too low|fable 5 requires usage credits|usage limit reached|you(?:'|’)re out of extra usage)[.!]?\\s*$",
            ],
            suggestedActionID: "restoreCredits"
        ),
        AgentStallPattern(
            identifier: "codex.usage-limit-banner",
            providers: ["codex"],
            cause: .quotaExhausted,
            requiredFragments: ["usage limit"],
            anyFragments: [
                "you've hit your usage limit",
                "you’ve hit your usage limit",
                "you've reached your usage limit",
                "you’ve reached your usage limit",
                "you've exceeded your usage limit",
                "you’ve exceeded your usage limit",
                "you have hit your usage limit",
                "you have reached your usage limit",
                "you have exceeded your usage limit",
                "purchase more credits",
            ],
            regularExpressions: [
                "(?m)^\\s*(?:you(?:'|’)ve|you have) (?:hit|reached|exceeded) your usage limit\\b[^\\n]*$",
            ],
            suggestedActionID: "restoreCredits"
        ),
        AgentStallPattern(
            identifier: "provider.usage-limit-banner",
            providers: ["claude", "codex"],
            cause: .quotaExhausted,
            requiredFragments: ["usage limit"],
            regularExpressions: [
                "(?m)^\\s*(?:you(?:'|’)ve|you have) (?:hit|reached|exceeded) your usage limit\\b[^\\n]*$",
                "(?m)^\\s*your usage limit has been (?:reached|exceeded)\\b[^\\n]*$",
                "(?m)^\\s*usage limit (?:reached|exceeded)\\b[^\\n]*$",
            ],
            suggestedActionID: "restoreCredits"
        ),
        AgentStallPattern(
            identifier: "codex.usage-limit-signal",
            providers: ["codex"],
            cause: .quotaExhausted,
            requiredFragments: ["usage_limit_exceeded"],
            anyFragments: ["codex_error_info", "error", "usage_limit_exceeded"],
            requiresStructuredEvidence: true,
            suggestedActionID: "restoreCredits"
        ),
        AgentStallPattern(
            identifier: "provider.credit-limit",
            providers: ["claude", "codex"],
            cause: .quotaExhausted,
            anyFragments: [
                "credit limit reached",
                "credit limit exceeded",
                "insufficient credits",
                "usage limit exceeded",
                "quota exhausted",
                "quota exceeded",
                "usage_limit_exceeded",
            ],
            regularExpressions: [
                "(?m)^\\s*(?:(?:api|http|request|response|provider)\\s+)?(?:error|failure|failed)\\s*[:：-][^\\n]{0,160}\\b(?:credit limit (?:reached|exceeded)|insufficient credits|usage limit exceeded|quota (?:exhausted|exceeded)|usage_limit_exceeded)\\b",
                "(?m)^\\s*(?:credit limit (?:reached|exceeded)|insufficient credits|usage limit exceeded|quota (?:exhausted|exceeded)|usage_limit_exceeded)[.!]?\\s*$",
            ],
            suggestedActionID: "restoreCredits"
        ),
        AgentStallPattern(
            identifier: "provider.authentication-expired",
            providers: ["claude", "codex"],
            cause: .authenticationExpired,
            requiredFragments: ["error"],
            anyFragments: [
                "authentication expired",
                "session expired",
                "login required",
                "unauthorized",
                "invalid api key",
                "invalid api token",
                "invalid auth token",
                "authentication error",
                "authentication failed",
            ],
            regularExpressions: [
                "(?m)^\\s*(?:(?:api|http|request|response|provider)\\s+)?(?:error|failure|failed)\\s*[:：-][^\\n]{0,160}\\b(?:authentication expired|session expired|login required|unauthorized|invalid api key|invalid api token|authentication (?:error|failed))\\b",
            ],
            suggestedActionID: "reauthenticate"
        ),
        AgentStallPattern(
            identifier: "provider.authentication-expired.explicit",
            providers: ["claude", "codex"],
            cause: .authenticationExpired,
            anyFragments: [
                "authentication expired",
                "session expired",
                "session has expired",
                "not logged in",
                "please run /login",
                "login required",
                "invalid api key",
                "invalid api token",
                "invalid auth token",
            ],
            regularExpressions: [
                "(?m)^\\s*(?:(?:your |the )?(?:authentication expired|session (?:has )?expired|login required)|not logged in|please run /login|invalid (?:api key|api token|auth token))(?:\\s*[.!·—-].*)?$",
            ],
            suggestedActionID: "reauthenticate"
        ),
        AgentStallPattern(
            identifier: "provider.authentication-expired.status",
            providers: ["claude", "codex"],
            cause: .authenticationExpired,
            regularExpressions: [
                "(?m)^\\s*(?:(?:api|http|request|response)\\s+)?(?:error|failure|failed)\\s*[:：=-]\\s*(?:http\\s*)?401\\b[^\\n]*$",
                "(?m)^\\s*(?:(?:api|http|request|response)\\s+)?(?:error|status|response)\\s*[:：=-]\\s*(?:http\\s*)?401(?:\\s+unauthorized)?[.!]?\\s*$",
                "(?m)^\\s*(?:(?:api|http|request|response)\\s+)?(?:error|failure|failed)\\s*\\(\\s*(?:status|http)\\s*[:=]?\\s*401\\b[^)]*\\)(?:\\s*[:：=-]\\s*)?[^\\n]*$",
                "(?m)^\\s*http\\s+401\\s+unauthorized[.!]?\\s*$",
            ],
            suggestedActionID: "reauthenticate"
        ),
        AgentStallPattern(
            identifier: "provider.authentication-expired.token-banner",
            providers: ["claude", "codex"],
            cause: .authenticationExpired,
            anyFragments: [
                "access token has expired",
                "token has expired",
                "token expired",
                "please log in again",
                "please sign in again",
            ],
            regularExpressions: [
                "(?m)^\\s*(?:your |the )?(?:access token has expired|token has expired|token expired|please log in again|please sign in again)(?:[.!].*)?$",
            ],
            suggestedActionID: "reauthenticate"
        ),
        AgentStallPattern(
            identifier: "provider.rate-limit",
            providers: ["claude", "codex"],
            cause: .rateLimit,
            anyFragments: ["rate limit", "too many requests", "rate_limit", "ratelimit"],
            regularExpressions: [
                "(?m)^\\s*(?:(?:api|http|request|response|provider)\\s+)?(?:error|failure|failed)\\s*[:：-][^\\n]{0,160}\\b(?:rate[ _-]?limit(?:[ _-]?(?:ed|reached|exceeded))?|too many requests|429)\\b",
                "(?m)^\\s*(?:rate[ _-]?limit(?:[ _-]?(?:ed|reached|exceeded))?|(?:429\\s+)?too many requests|429)(?:\\s*\\(?429\\)?)?[.!]?\\s*$",
            ],
            retryActionID: "replayLastPrompt",
            suggestedActionID: "retryAutomatically"
        ),
        AgentStallPattern(
            identifier: "provider.rate-limit.status",
            providers: ["claude", "codex"],
            cause: .rateLimit,
            regularExpressions: [
                "(?m)^\\s*(?:(?:api|http|request|response)\\s+)?(?:error|failure|failed)\\s*[:：=-]\\s*(?:http\\s*)?429\\b[^\\n]*$",
                "(?m)^\\s*(?:(?:api|http|request|response)\\s+)?(?:error|status|response)\\s*[:：=-]\\s*(?:http\\s*)?429(?:\\s+(?:too many requests|rate[ _-]?limit(?:[ _-]?(?:ed|reached|exceeded))?))?[.!]?\\s*$",
                "(?m)^\\s*(?:(?:api|http|request|response)\\s+)?(?:error|failure|failed)\\s*\\(\\s*(?:status|http)\\s*[:=]?\\s*429\\b[^)]*\\)(?:\\s*[:：=-]\\s*)?[^\\n]*$",
                "(?m)^\\s*http\\s+429\\s+(?:too many requests|rate[ _-]?limit(?:[ _-]?(?:ed|reached|exceeded))?)[.!]?\\s*$",
            ],
            retryActionID: "replayLastPrompt",
            suggestedActionID: "retryAutomatically"
        ),
        AgentStallPattern(
            identifier: "anthropic.overloaded-banner",
            providers: ["claude"],
            cause: .overload,
            anyFragments: [
                "api overloaded",
                "529 overloaded",
                "repeated 529 overloaded errors",
            ],
            regularExpressions: [
                "(?m)^\\s*(?:api overloaded|(?:repeated )?529 overloaded(?: errors)?)[.!]?\\s*$",
            ],
            retryActionID: "replayLastPrompt",
            suggestedActionID: "retryAutomatically"
        ),
        AgentStallPattern(
            identifier: "provider.overloaded",
            providers: ["claude", "codex"],
            cause: .overload,
            anyFragments: ["overloaded", "temporarily unavailable", "service unavailable"],
            regularExpressions: [
                "(?m)^\\s*(?:(?:api|http|request|response|provider|server)\\s+)?(?:error|failure|failed)\\s*[:：-][^\\n]{0,160}\\b(?:overloaded|temporarily unavailable|service unavailable)\\b",
                "(?m)^\\s*(?:server (?:is )?overloaded|temporarily unavailable|service unavailable)[.!]?\\s*$",
                "(?m)^\\s*(?:the )?(?:api|service|server|provider)\\s+(?:is\\s+)?(?:currently\\s+)?(?:overloaded|temporarily unavailable|unavailable)(?:[.!;:—-].*)?\\s*$",
            ],
            retryActionID: "replayLastPrompt",
            suggestedActionID: "retryAutomatically"
        ),
        AgentStallPattern(
            identifier: "codex.overloaded.banner",
            providers: ["codex"],
            cause: .overload,
            requiredFragments: ["try again later"],
            regularExpressions: [
                "(?m)^\\s*try again later[.!]?\\s*$",
            ],
            retryActionID: "replayLastPrompt",
            requiresStructuredEvidence: true,
            suggestedActionID: "retryAutomatically"
        ),
        AgentStallPattern(
            identifier: "codex.model-capacity",
            providers: ["codex"],
            cause: .overload,
            requiredFragments: ["selected model is at capacity"],
            regularExpressions: [
                "(?m)^\\s*selected model is at capacity\\.?(?: please try a different model\\.?)?\\s*$",
            ],
            retryActionID: "replayLastPrompt",
            suggestedActionID: "retryAutomatically"
        ),
        AgentStallPattern(
            identifier: "codex.server-overloaded",
            providers: ["codex"],
            cause: .overload,
            requiredFragments: ["try again later"],
            anyFragments: ["server_overloaded", "codex_error_info", "error"],
            retryActionID: "replayLastPrompt",
            requiresStructuredEvidence: true,
            suggestedActionID: "retryAutomatically"
        ),
        AgentStallPattern(
            identifier: "codex.server-overloaded-signal",
            providers: ["codex"],
            cause: .overload,
            requiredFragments: ["server_overloaded"],
            anyFragments: ["codex_error_info", "event_msg error", "server_overloaded"],
            retryActionID: "replayLastPrompt",
            requiresStructuredEvidence: true,
            suggestedActionID: "retryAutomatically"
        ),
        AgentStallPattern(
            identifier: "codex.server-overloaded-banner",
            providers: ["codex"],
            cause: .overload,
            requiredFragments: ["server overloaded"],
            regularExpressions: [
                "(?m)^\\s*server overloaded(?:; retry later)?[.!]?\\s*$",
            ],
            retryActionID: "replayLastPrompt",
            suggestedActionID: "retryAutomatically"
        ),
        AgentStallPattern(
            identifier: "codex.stream-disconnected",
            providers: ["codex"],
            cause: .transientTransport,
            requiredFragments: ["stream disconnected"],
            anyFragments: ["before completion", "response_stream_disconnected", "error"],
            retryActionID: "replayLastPrompt",
            requiresStructuredEvidence: true,
            suggestedActionID: "retryAutomatically"
        ),
        AgentStallPattern(
            identifier: "codex.transport-signal",
            providers: ["codex"],
            cause: .transientTransport,
            anyFragments: [
                "http_connection_failed",
                "response_stream_connection_failed",
                "response_stream_failed",
                "connection_failed",
                "internal_server_error",
            ],
            regularExpressions: [
                "(?m)^\\s*[^\\n]{0,100}\\bcodex_error_info\\s*[:=]\\s*(?:http_connection_failed|response_stream_connection_failed|response_stream_failed|connection_failed|internal_server_error)\\b[^\\n]*$",
            ],
            retryActionID: "replayLastPrompt",
            requiresStructuredEvidence: true,
            suggestedActionID: "retryAutomatically"
        ),
        AgentStallPattern(
            identifier: "anthropic.connection-banner",
            providers: ["claude"],
            cause: .transientTransport,
            anyFragments: [
                "unable to connect to api",
                "couldn't connect through your proxy",
                "couldn’t connect through your proxy",
            ],
            regularExpressions: [
                "(?m)^\\s*(?:unable to connect to api|couldn(?:'|’)t connect through your proxy)(?:\\s*\\([^\\n]*\\))?[.!]?\\s*$",
            ],
            retryActionID: "replayLastPrompt",
            suggestedActionID: "retryAutomatically"
        ),
        AgentStallPattern(
            identifier: "anthropic.api-status",
            providers: ["claude"],
            cause: .transientTransport,
            regularExpressions: [
                "(?m)^\\s*api error \\(status 5[0-9]{2}\\)(?:\\s*[:：-]\\s*(?:internal server error|bad gateway|service unavailable|gateway timeout|overloaded))?[.!]?\\s*$",
            ],
            retryActionID: "replayLastPrompt",
            suggestedActionID: "retryAutomatically"
        ),
        AgentStallPattern(
            identifier: "provider.transport",
            providers: ["claude", "codex"],
            cause: .transientTransport,
            anyFragments: [
                "connection refused",
                "connection reset",
                "connection timed out",
                "connection timeout",
                "network error",
                "econnreset",
                "econnrefused",
                "http 500",
                "http 502",
                "http 503",
                "http 504",
                "internal server error",
                "bad gateway",
                "gateway timeout",
            ],
            regularExpressions: [
                "(?m)^\\s*(?:(?:api|http|network|request|response)\\s+)?(?:error|failure|failed)\\s*[:：-][^\\n]{0,160}\\b(?:connection refused|connection reset|connection timed out|connection timeout|network error|econnreset|econnrefused|http 5[0-9]{2}|internal server error|bad gateway|gateway timeout)\\b",
                "(?m)^\\s*(?:connection refused|connection reset(?: by peer)?|connection timed out|connection timeout|network error|econnreset|econnrefused|internal server error|bad gateway|gateway timeout)[.!]?\\s*$",
            ],
            retryActionID: "replayLastPrompt",
            suggestedActionID: "retryAutomatically"
        ),
        AgentStallPattern(
            identifier: "provider.transport.status",
            providers: ["claude", "codex"],
            cause: .transientTransport,
            regularExpressions: [
                "(?m)^\\s*(?:(?:api|http|request|response)\\s+)?(?:error|failure|failed)\\s*[:：=-]\\s*(?:http\\s*)?5[0-9]{2}\\b[^\\n]*$",
                "(?m)^\\s*(?:(?:api|http|request|response)\\s+)?(?:error|status|response)\\s*[:：=-]\\s*(?:http\\s*)?5[0-9]{2}(?:\\s+(?:internal server error|bad gateway|service unavailable|gateway timeout|server overloaded))?[.!]?\\s*$",
                "(?m)^\\s*(?:(?:api|http|request|response|provider)\\s+)?(?:error|failure|failed)\\s*\\(\\s*(?:status|http)\\s*[:=]?\\s*5[0-9]{2}\\b[^)]*\\)(?:\\s*[:：=-]\\s*)?[^\\n]*$",
                "(?m)^\\s*http\\s+5[0-9]{2}\\s+(?:internal server error|bad gateway|service unavailable|gateway timeout|server overloaded)\\b[^\\n]*$",
                "(?m)^\\s*5[0-9]{2}\\s+(?:internal server error|bad gateway|service unavailable|gateway timeout)\\b[^\\n]*$",
            ],
            retryActionID: "replayLastPrompt",
            suggestedActionID: "retryAutomatically"
        ),
    ]
}
