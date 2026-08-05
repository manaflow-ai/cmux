/// UI-test flags parsed from an explicit environment dictionary.
public struct UITestEnvironmentConfig: Equatable, Sendable {
    private let environment: [String: String]

    /// Creates a UI-test config from explicit environment values.
    ///
    /// - Parameter environment: Process-style environment keys and values.
    public init(environment: [String: String]) {
        self.environment = environment
    }

    /// Whether the standalone agent-chat preview is enabled.
    public var agentChatPreviewEnabled: Bool {
        #if DEBUG
        return environment["CMUX_UITEST_AGENT_CHAT_PREVIEW"] == "1"
        #else
        return false
        #endif
    }

    /// Whether the workspace-shaped agent-chat preview is enabled.
    public var agentChatInlinePreviewEnabled: Bool {
        #if DEBUG
        return environment["CMUX_UITEST_AGENT_CHAT_INLINE_PREVIEW"] == "1"
        #else
        return false
        #endif
    }

    /// The requested transcript density when the launch value is supported.
    public var transcriptDensity: String? {
        let value = environment["CMUX_UITEST_TRANSCRIPT_DENSITY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard value == "comfortable" || value == "compact" else { return nil }
        return value
    }

    /// Whether the deterministic onboarding preview is enabled.
    public var onboardingPreviewEnabled: Bool {
        #if DEBUG
        return environment["CMUX_UITEST_ONBOARDING_PREVIEW"] == "1"
        #else
        return false
        #endif
    }

    /// Whether the onboarding preview should show connection fallback.
    public var onboardingConnectionFallbackEnabled: Bool {
        #if DEBUG
        return environment["CMUX_UITEST_ONBOARDING_CONNECTION_FALLBACK"] == "1"
        #else
        return false
        #endif
    }

    /// Whether the deterministic pairing-scanner preview is enabled.
    public var pairingScannerPreviewEnabled: Bool {
        #if DEBUG
        return environment["CMUX_UITEST_SCANNER_PREVIEW"] == "1"
        #else
        return false
        #endif
    }
}
