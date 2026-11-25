import Foundation

/// Replaces known secret shapes in notification text with `[redacted]` before it leaves the Mac for
/// the feed (and from there APNs and the lock screen). A best-effort net, not a guarantee: terminal
/// notifications stay off by default (`feed.mirrorNotifications.terminal`) because program output can
/// hold secrets of any shape. The shapes are the Rust policy's (cmux-agent-pane-policy `prompt::scrub`).
nonisolated enum FeedSecretScrubber {
    static let marker = "[redacted]"

    /// `scrub` of the first 16 KiB characters of `text` (unbounded program output: the scrub ran on
    /// the main actor, cx-9c8m); a secret cut at the edge is still redacted.
    static func scrubPrefix(_ text: String) -> String {
        AgentPanePolicyFFI.text("prompt_scrub", ["text": text, "prefix": true]) ?? marker
    }

    /// `text` with its secrets redacted; the whole of it is the marker when the policy could not run.
    static func scrub(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return AgentPanePolicyFFI.text("prompt_scrub", ["text": text]) ?? marker
    }
}
