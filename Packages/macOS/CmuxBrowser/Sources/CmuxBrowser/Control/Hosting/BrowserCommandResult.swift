/// The outcome of one `browser.*` v2 control command, the package-side spelling
/// of the app target's former nested `TerminalController.V2CallResult`.
///
/// Carries an untyped (`Any`) success payload and an untyped error `data`
/// detail, exactly as the legacy nested enum did, so the app's
/// `typealias V2CallResult = BrowserCommandResult` keeps every existing
/// `.ok(_)` / `.err(code:message:data:)` construction and pattern match
/// resolving unchanged.
///
/// Intentionally **not** `Sendable`: the `Any` success payload and `Any?` error
/// `data` are the same untyped Foundation values the legacy enum threaded
/// through the worker lane's `nonisolated(unsafe)` hops while the command bodies
/// still build Foundation payloads. The typed counterpart that is `Sendable` is
/// `ControlCallResult` (CmuxControlSocket); bodies migrate onto it in the
/// ControlCommandCoordinator stage. Constraining the payload to `Sendable` now
/// would be a behavior change, not a faithful lift.
public enum BrowserCommandResult {
    /// The command succeeded with the given (untyped) result payload.
    case ok(Any)
    /// The command failed with a machine-readable `code`, a human-readable
    /// `message`, and optional structured `data`.
    case err(code: String, message: String, data: Any?)
}
