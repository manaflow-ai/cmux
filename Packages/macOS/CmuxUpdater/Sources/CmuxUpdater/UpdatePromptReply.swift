import Foundation
@preconcurrency public import Sparkle

/// Why cmux consumed a Sparkle update prompt.
///
/// Sparkle's later `dismissUpdateInstallation` callback does not identify the prompt or the
/// action that caused it. Recording the cause at the reply boundary lets the lifecycle owner
/// distinguish an explicit user choice from a controller transition or accepted install.
@MainActor
enum UpdatePromptReplySource: String {
    case user
    case superseded
    case installAttempt
}

/// A Sparkle prompt reply that can be sent at most once, with its consumption observable.
///
/// Sparkle's update-choice callback must be invoked exactly once per prompt; double-replying is
/// an API misuse. Wrapping it also gives the update flow the one bit the raw closure cannot:
/// whether this prompt was already answered. That bit disambiguates "the user answered this
/// prompt" from "the model state was clobbered by an unrelated emission" (for example a stale
/// prompt's Sparkle dismiss callback landing after a fresh check already resolved).
@MainActor
public final class UpdatePromptReply {
    let id = UUID()
    private var handler: (@Sendable (SPUUserUpdateChoice) -> Void)?
    var onConsumed: ((UpdatePromptReply, SPUUserUpdateChoice, UpdatePromptReplySource) -> Void)?

    /// The first choice sent to Sparkle, or `nil` until this prompt is answered.
    public private(set) var consumedChoice: SPUUserUpdateChoice?
    /// The cause of the first choice, or `nil` until this prompt is answered.
    private(set) var consumedSource: UpdatePromptReplySource?

    /// Wraps `handler` so it runs on the first call only.
    public init(_ handler: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        self.handler = handler
    }

    /// Whether a choice has already been sent.
    public var isConsumed: Bool {
        consumedChoice != nil
    }

    /// Sends `choice` to Sparkle; subsequent calls are no-ops.
    public func callAsFunction(_ choice: SPUUserUpdateChoice) {
        consume(choice, source: .user)
    }

    /// Sends an internally-caused choice to Sparkle; subsequent calls are no-ops.
    func consume(_ choice: SPUUserUpdateChoice, source: UpdatePromptReplySource) {
        guard let handler = self.handler else { return }
        self.handler = nil
        consumedChoice = choice
        consumedSource = source
        onConsumed?(self, choice, source)
        handler(choice)
    }
}
