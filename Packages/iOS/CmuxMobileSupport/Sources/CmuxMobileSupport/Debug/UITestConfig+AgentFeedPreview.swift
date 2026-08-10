import Foundation

public extension UITestConfig {
    static var agentFeedPreviewEnabled: Bool {
        agentFeedPreviewEnabled(
            from: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    static func agentFeedPreviewEnabled(
        from env: [String: String],
        arguments: [String] = []
    ) -> Bool {
        #if DEBUG
        env["CMUX_UITEST_AGENT_FEED_PREVIEW"] == "1"
            || arguments.contains("CMUX_UITEST_AGENT_FEED_PREVIEW=1")
        #else
        false
        #endif
    }
}
