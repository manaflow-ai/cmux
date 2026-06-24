import Foundation

/// Default-off feature flag gating the live agent-prose streaming preview.
///
/// Streaming scrapes the rendered terminal screen heuristically and is meant
/// for dogfood before it is trusted on by default, so it is an explicit opt-in
/// rather than a `cmux.json` product setting. Flip it at runtime (no relaunch)
/// with:
///
/// ```
/// defaults write <bundle-id> CMUXAgentChatProseStreaming -bool YES
/// ```
///
/// The value is read live on every poll so toggling takes effect immediately.
enum AgentChatProseStreamingFlag {
    static let defaultsKey = "CMUXAgentChatProseStreaming"

    /// Whether the live streaming preview is enabled. Defaults to `false`.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
