import Foundation

/// Debug-only Agent Feed fixture controls.
extension UITestConfig {
    /// A single rich-text question for the question UI's rendering checks.
    public static var agentFeedQuestionMarkdownPreviewEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CMUX_UITEST_FEED_QUESTION_MARKDOWN_PREVIEW"] == "1"
        #else
        false
        #endif
    }

    public static var agentFeedDecisionPreviewLightAppearanceEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CMUX_UITEST_FEED_DECISION_PREVIEW_LIGHT"] == "1"
        #else
        false
        #endif
    }

    /// The retained row count for Feed scroll stress runs.
    public static var agentFeedDecisionPreviewItemCount: Int? {
        agentFeedDecisionPreviewItemCount(from: ProcessInfo.processInfo.environment)
    }

    static func agentFeedDecisionPreviewItemCount(from env: [String: String]) -> Int? {
        #if DEBUG
        guard let raw = env["CMUX_UITEST_FEED_DECISION_PREVIEW_COUNT"],
              let count = Int(raw) else { return nil }
        return min(max(count, 1), 400)
        #else
        return nil
        #endif
    }

    /// Makes the Feed fixture inject retained agent activity while a UI test
    /// scrolls the production list.
    public static var agentFeedDecisionPreviewScrollStressEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CMUX_UITEST_FEED_DECISION_PREVIEW_SCROLL_STRESS"] == "1"
        #else
        false
        #endif
    }
}
