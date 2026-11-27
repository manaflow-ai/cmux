import Foundation

/// Replaces known secret shapes in notification text with `[redacted]` before it leaves the Mac for
/// the feed (and from there APNs and the lock screen). The shapes are the Rust policy's
/// (`cmux-agent-pane-policy` `prompt::scrub`).
nonisolated enum FeedSecretScrubber {
    static let marker = "[redacted]"

    /// `scrub` of the first 16 KiB of `text`.
    static func scrubPrefix(_ text: String) -> String {
        AgentPanePolicyFFI.text("prompt_scrub", ["text": text, "prefix": true]) ?? marker
    }

    static func scrub(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return AgentPanePolicyFFI.text("prompt_scrub", ["text": text]) ?? marker
    }
}
