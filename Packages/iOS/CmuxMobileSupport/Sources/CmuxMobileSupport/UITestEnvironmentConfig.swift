/// UI-test flags parsed from an explicit environment dictionary.
public struct UITestEnvironmentConfig: Equatable, Sendable {
    private let environment: [String: String]

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
}
