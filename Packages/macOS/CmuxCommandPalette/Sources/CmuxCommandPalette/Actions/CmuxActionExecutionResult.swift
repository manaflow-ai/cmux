/// Observable outcome returned by every action executor.
public enum CmuxActionExecutionResult: Sendable, Equatable {
    /// The action completed synchronously.
    case completed
    /// The action accepted asynchronous work that has not completed yet.
    case queued
    /// The action presented UI that owns the remaining interaction.
    case presented
    /// The caller omitted required statically declared arguments.
    case requiresArguments([CmuxActionArgumentDefinition])
    /// The caller supplied argument names that the action does not declare.
    case invalidArguments([String])
    /// The caller supplied values that do not match declared argument types.
    case invalidArgumentValues([String])
    /// The action rejected the invocation or failed to start.
    case failed(code: String, message: String)
}
