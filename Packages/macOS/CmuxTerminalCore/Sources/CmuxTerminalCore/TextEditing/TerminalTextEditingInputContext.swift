/// Tracks the shell prompt that may receive macOS editing gestures.
/// A prompt belongs to one foreground process and one native runtime lifetime.
public struct TerminalTextEditingInputContext: Equatable, Sendable {
    private var promptProcessID: UInt64?
    private var promptRuntimeGeneration: UInt64?

    public init() {}

    /// Records a prompt only when the caller has identified a supported shell.
    public mutating func reportPrompt(
        isSupportedShellPrompt: Bool,
        foregroundProcessID: UInt64?,
        runtimeGeneration: UInt64
    ) {
        promptProcessID = isSupportedShellPrompt ? foregroundProcessID : nil
        promptRuntimeGeneration = isSupportedShellPrompt ? runtimeGeneration : nil
    }

    /// Withdraws permission synchronously when input submits a command.
    public mutating func commandWasSubmitted() {
        promptProcessID = nil
        promptRuntimeGeneration = nil
    }

    /// Returns whether the current input owner can receive translated gestures.
    public func allowsGestures(
        enabled: Bool,
        foregroundProcessID: UInt64?,
        runtimeGeneration: UInt64,
        anotherInputModeOwnsKeys: Bool = false
    ) -> Bool {
        guard enabled, !anotherInputModeOwnsKeys else { return false }
        guard let promptProcessID,
              promptProcessID > 0,
              let promptRuntimeGeneration,
              promptRuntimeGeneration == runtimeGeneration,
              foregroundProcessID == promptProcessID else {
            return false
        }
        return true
    }
}
