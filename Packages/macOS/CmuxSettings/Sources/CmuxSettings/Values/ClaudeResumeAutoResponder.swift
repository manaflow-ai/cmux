import Foundation

/// One-shot responder armed for a single resumed Claude pane. The controller
/// feeds it the pane's rendered screen on each poll; it returns the keys to send
/// when the menu appears, then the controller confirms delivery so a failed
/// synthetic-key send can be retried on the next screen sample.
public final class ClaudeResumeAutoResponder {
    /// The configured resume behavior for this pane.
    public let mode: ClaudeResumeMode
    /// Whether the controller has confirmed that the planned keys were delivered.
    public private(set) var hasResponded = false
    private let prompt: ClaudeResumePrompt

    /// Creates a one-shot responder for a restored Claude pane.
    public init(mode: ClaudeResumeMode, prompt: ClaudeResumePrompt = ClaudeResumePrompt()) {
        self.mode = mode
        self.prompt = prompt
    }

    /// Returns the keys to send if the menu is now visible and we haven't already
    /// responded; nil otherwise. The controller calls ``confirmDelivered()`` only
    /// after every planned key reaches, or is queued for, the terminal surface.
    public func evaluate(screen: String) -> [ClaudeResumeKey]? {
        guard !hasResponded, mode != .ask else { return nil }
        return prompt.keystrokes(for: mode, in: screen)
    }

    /// Marks the responder complete after every planned key is accepted.
    public func confirmDelivered() {
        hasResponded = true
    }
}
