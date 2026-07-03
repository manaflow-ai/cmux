@preconcurrency public import Sparkle

/// A Sparkle prompt reply that can be sent at most once, with its consumption observable.
///
/// Sparkle's update-choice callback must be invoked exactly once per prompt; double-replying is
/// an API misuse. Wrapping it also gives the update flow the one bit the raw closure cannot:
/// whether this prompt was already answered. That bit disambiguates "the user answered this
/// prompt" from "the model state was clobbered by an unrelated emission" (for example a stale
/// prompt's Sparkle dismiss callback landing after a fresh check already resolved).
@MainActor
public final class UpdatePromptReply {
    private var handler: (@Sendable (SPUUserUpdateChoice) -> Void)?

    /// Wraps `handler` so it runs on the first call only.
    public init(_ handler: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        self.handler = handler
    }

    /// Whether a choice has already been sent.
    public var isConsumed: Bool {
        handler == nil
    }

    /// Sends `choice` to Sparkle; subsequent calls are no-ops.
    public func callAsFunction(_ choice: SPUUserUpdateChoice) {
        let handler = self.handler
        self.handler = nil
        handler?(choice)
    }
}
