import Foundation

/// A value-typed bundle of closures wiring the composer to the app layer.
///
/// The chat view never holds a reference to the terminal, panel, or any app
/// store; sending is a single closure injected from the composition root
/// (snapshot-boundary style, like ``ChatRowActions``). When no send target
/// exists, the host passes `nil` to ``AgentChatView`` and the composer is not
/// shown.
@MainActor
public struct ChatComposerActions {
    /// Sends the composed text to the agent's terminal.
    ///
    /// Returns `true` when the text was accepted (sent or queued) so the
    /// composer can clear its input, `false` when the target terminal is gone
    /// or rejected the input.
    public let send: (String) -> Bool

    /// Creates a composer action bundle.
    ///
    /// - Parameter send: Routes the composed text to the agent terminal;
    ///   returns whether the text was accepted.
    public init(send: @escaping (String) -> Bool) {
        self.send = send
    }
}
