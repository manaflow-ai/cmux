// SPDX-License-Identifier: MIT

/// OSC 133 shell-integration semantic kind. Populated only when the
/// surface's shell emits OSC 133 markers (currently zsh, via cmux's
/// `.zshenv` injection — see spec §15 and D27).
public enum SemanticKind: String, Sendable, Codable, Hashable {
    /// First line of a shell prompt.
    case prompt
    /// User input region that follows a prompt.
    case input
    /// Command output region that follows input.
    case output
    /// Continuation row of a multi-line prompt.
    case promptContinuation = "prompt_continuation"
}
